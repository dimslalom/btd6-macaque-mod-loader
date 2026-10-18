using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Reflection.Emit;
using System.Runtime.InteropServices;
using HarmonyLib;
using Il2CppInterop.Runtime;

namespace MelonMacFixes
{
    // Il2CppInterop's Harmony backend (Il2CppDetourMethodPatcher) builds a native -> managed trampoline per patched
    // il2cpp method. For parameters whose type is a non-blittable struct (an Il2CppSystem.ValueType wrapper, e.g.
    // StreamingContext or AsyncOperationHandle<T>), it assumes the Windows x64 rule: the struct arrives as a pointer.
    // On macOS / SysV x64 il2cpp's C++ passes such structs by value: in one or two registers when <= 16 bytes,
    // otherwise copied onto the stack. The trampoline then reads the wrong register, boxes garbage and crashes.
    //
    // Fix (same idea Il2CppInterop already uses on 32-bit): declare those parameters as a blittable stand-in struct
    // of the same size and SysV classification, so CoreCLR receives the bytes exactly as il2cpp passes them, and take
    // the argument's address (ldarga) before il2cpp_value_box instead of treating the argument as the address.
    internal static class SysVStructs
    {
        private static Type _valueTypeBase;            // Il2CppSystem.ValueType
        private static Func<Type, Type> _origNativeType;

        public static void Apply(HarmonyLib.Harmony harmony, MelonLoader.MelonLogger.Instance log)
        {
            var helpers = AccessTools.TypeByName("Il2CppInterop.Runtime.Injection.TrampolineHelpers")
                ?? throw new Exception("TrampolineHelpers not found");
            var nativeType = AccessTools.Method(helpers, "NativeType") ?? throw new Exception("NativeType not found");
            _origNativeType = (Func<Type, Type>)Delegate.CreateDelegate(typeof(Func<Type, Type>), nativeType);

            var patcher = AccessTools.TypeByName("Il2CppInterop.HarmonySupport.Il2CppDetourMethodPatcher")
                ?? throw new Exception("Il2CppDetourMethodPatcher not found");
            var gen = AccessTools.Method(patcher, "GenerateNativeToManagedTrampoline")
                ?? throw new Exception("GenerateNativeToManagedTrampoline not found");
            var conv = AccessTools.Method(patcher, "EmitConvertArgumentToManaged")
                ?? throw new Exception("EmitConvertArgumentToManaged not found");

            _nativeTypeOrig = nativeType;
            harmony.Patch(gen, transpiler: new HarmonyMethod(typeof(SysVStructs), nameof(TranspileParamTypes)),
                postfix: DebugOn ? new HarmonyMethod(typeof(SysVStructs), nameof(DumpTrampoline)) : null);
            harmony.Patch(conv, transpiler: new HarmonyMethod(typeof(SysVStructs), nameof(TranspileIs64Bit)));
            if (_paramSites == 0 || _is64Sites == 0)
                throw new Exception($"transpilers matched {_paramSites} param-type sites and {_is64Sites} pointer-rule sites");
            log.Msg($"SysV struct ABI fix applied to Il2CppInterop Harmony trampolines ({_paramSites}+{_is64Sites} sites)");
        }

        private static bool DebugOn => Environment.GetEnvironmentVariable("MELONFIX_DEBUG") is { Length: > 0 } v && v != "0";

        // Debug aid: logs the IL of every trampoline that uses a stand-in struct (the result is a MonoMod
        // DynamicMethodDefinition; read through reflection so we don't need its assemblies at compile time).
        private static void DumpTrampoline(object __result)
        {
            try
            {
                var def = __result?.GetType().GetProperty("Definition")?.GetValue(__result);
                if (def == null) return;
                var parms = (System.Collections.IEnumerable)def.GetType().GetProperty("Parameters").GetValue(def);
                bool standIn = false;
                foreach (var p in parms)
                    if ((p.GetType().GetProperty("ParameterType").GetValue(p)?.ToString() ?? "").Contains("StandIns")) standIn = true;
                if (!standIn) return;
                var body = def.GetType().GetProperty("Body").GetValue(def);
                var instrs = (System.Collections.IEnumerable)body.GetType().GetProperty("Instructions").GetValue(body);
                var sb = new System.Text.StringBuilder($"[MelonMacFixes] trampoline IL for {def}:\n");
                foreach (var ins in instrs) sb.Append("    ").Append(ins).Append('\n');
                MelonLoader.MelonLogger.Msg(sb.ToString());
            }
            catch (Exception e) { MelonLoader.MelonLogger.Warning($"[MelonMacFixes] IL dump failed: {e.Message}"); }
        }

        private static MethodInfo _nativeTypeOrig;
        private static int _paramSites, _is64Sites;

        // ldftn TrampolineHelpers.NativeType (used as Select(NativeType) for the parameter list) -> ldftn NativeTypeParam
        private static IEnumerable<CodeInstruction> TranspileParamTypes(IEnumerable<CodeInstruction> instructions)
        {
            var mine = AccessTools.Method(typeof(SysVStructs), nameof(NativeTypeParam));
            foreach (var ci in instructions)
            {
                if (ci.opcode == OpCodes.Ldftn && ci.operand is MethodInfo m && m == _nativeTypeOrig)
                {
                    ci.operand = mine;
                    _paramSites++;
                }
                yield return ci;
            }
        }

        // Environment.Is64BitProcess ? Ldarg : Ldarga_S  ->  StructsByPointer() ? Ldarg : Ldarga_S
        private static IEnumerable<CodeInstruction> TranspileIs64Bit(IEnumerable<CodeInstruction> instructions)
        {
            var is64 = AccessTools.PropertyGetter(typeof(Environment), nameof(Environment.Is64BitProcess));
            var mine = AccessTools.Method(typeof(SysVStructs), nameof(StructsByPointer));
            foreach (var ci in instructions)
            {
                if (ci.Calls(is64))
                {
                    ci.operand = mine;
                    _is64Sites++;
                }
                yield return ci;
            }
        }

        public static bool StructsByPointer() =>
            Environment.Is64BitProcess && RuntimeInformation.IsOSPlatform(OSPlatform.Windows);

        public static Type NativeTypeParam(Type managedType)
        {
            _valueTypeBase ??= AccessTools.TypeByName("Il2CppSystem.ValueType");
            if (_valueTypeBase != null && !StructsByPointer() && Environment.Is64BitProcess && !managedType.IsByRef &&
                managedType.IsSubclassOf(_valueTypeBase))
            {
                try { return StandInFor(managedType); }
                catch (Exception e) { MelonLoader.MelonLogger.Error($"[MelonMacFixes] stand-in for {managedType}: {e.Message}"); }
            }
            return _origNativeType(managedType);
        }

        // ---- SysV classification of an il2cpp value type ----

        private static Type StandInFor(Type managedType)
        {
            IntPtr klass = Il2CppClassPointerStore.GetNativeClassPointer(managedType);
            if (klass == IntPtr.Zero) throw new Exception("no il2cpp class");
            uint align = 0;
            int size = IL2CPP.il2cpp_class_value_size(klass, ref align);
            if (size > 16)
            {
                int rounded = (size + 7) & ~7;
                return typeof(SysVStructs).Assembly.GetType($"MelonMacFixes.StandIns.M{rounded}")
                    ?? throw new Exception($"no stand-in for {size}-byte struct");
            }
            // Register-passed: one or two eightbytes, each INTEGER (L) or SSE (D). Rounding up to whole eightbytes is
            // harmless: the trampoline only boxes `size` bytes from the argument's address.
            var cls = new char[2];
            Classify(klass, 0, cls, 0);
            string key = (cls[0] == 'S' ? "D" : "L") + (size > 8 ? (cls[1] == 'S' ? "D" : "L") : "");
            return typeof(SysVStructs).Assembly.GetType($"MelonMacFixes.StandIns.R{key}");
        }

        private const int IL2CPP_TYPE_R4 = 0x0c, IL2CPP_TYPE_R8 = 0x0d, IL2CPP_TYPE_VALUETYPE = 0x11, IL2CPP_TYPE_GENERICINST = 0x15;

        private static void Classify(IntPtr klass, int baseOffset, char[] cls, int depth)
        {
            IntPtr iter = IntPtr.Zero, field;
            while ((field = IL2CPP.il2cpp_class_get_fields(klass, ref iter)) != IntPtr.Zero)
            {
                if ((IL2CPP.il2cpp_field_get_flags(field) & 0x10) != 0) continue;    // static
                IntPtr ft = IL2CPP.il2cpp_field_get_type(field);
                int off = baseOffset + (int)IL2CPP.il2cpp_field_get_offset(field) - 2 * IntPtr.Size;   // drop object header
                int tt = IL2CPP.il2cpp_type_get_type(ft);
                if ((tt == IL2CPP_TYPE_VALUETYPE || tt == IL2CPP_TYPE_GENERICINST) && depth < 8)
                {
                    IntPtr fk = IL2CPP.il2cpp_class_from_type(ft);
                    if (fk != IntPtr.Zero && !IL2CPP.il2cpp_class_is_enum(fk) && IL2CPP.il2cpp_class_is_valuetype(fk))
                    {
                        Classify(fk, off, cls, depth + 1);
                        continue;
                    }
                }
                int eb = off / 8;
                if (eb < 0 || eb > 1) continue;
                bool sse = tt == IL2CPP_TYPE_R4 || tt == IL2CPP_TYPE_R8;
                if (!sse) cls[eb] = 'I';
                else if (cls[eb] != 'I') cls[eb] = 'S';
            }
        }
    }
}
