using System;
using System.Collections;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using HarmonyLib;
using MelonLoader;

[assembly: MelonInfo(typeof(MelonMacFixes.MacFixes), "MelonMacFixes", "1.2.0", "melonfix")]
[assembly: MelonGame]

namespace MelonMacFixes
{
    // Fixes for MelonLoader 0.7.3 on macOS (CoreCLR) that need managed code.
    //
    // Il2CppICallInjector: MelonLoader attaches its il2cpp_resolve_icall hook through
    // BootstrapInterop.NativeHookAttach, which first runs CoreClrDelegateFixer.SanityCheckDetour. That calls
    // ClrMD's DataTarget.CreateSnapshotAndAttach, which throws PlatformNotSupportedException on macOS, so the hook
    // is never attached and Unity icalls the game itself doesn't use stay unresolved (for example
    // Transform::SetAsLastSibling). Harmony patches on MelonLoader's own managed methods don't take effect here,
    // so instead we finish the half-built hook ourselves through NativeHookAttachDirect (no sanity check).
    public class MacFixes : MelonPlugin
    {
        private static Delegate _detourKeepAlive;   // the function pointer handed to native code must stay alive

        public override unsafe void OnPreModsLoaded()
        {
            if (!RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
                return;
            try { AttachICallInjector(); }
            catch (Exception e) { LoggerInstance.Error($"ICall injector fix failed: {e}"); }
            try
            {
                SysVStructs.Apply(HarmonyInstance, LoggerInstance);
                if (TryGetMelonfixExport("melonfix_set_abi_fixed", out var setFixed))
                    ((delegate* unmanaged<int, void>)setFixed)(1);
            }
            catch (Exception e) { LoggerInstance.Error($"SysV struct ABI fix failed: {e}"); }
            try { SetupAutotest(); } catch (Exception e) { LoggerInstance.Warning($"autotest setup: {e.Message}"); }
            try { RegisterCrashStackLogger(); }
            catch (Exception e) { LoggerInstance.Warning($"crash stack logger not registered: {e.Message}"); }
        }

        // Debug aid: MELONFIX_AUTOTEST=modsmenu opens Mod Helper's Mods menu ~8 s after the main menu scene loads.
        private long _autotestAt = -1;
        private void SetupAutotest()
        {
            if (Environment.GetEnvironmentVariable("MELONFIX_AUTOTEST") != "modsmenu") return;
            MelonEvents.OnSceneWasInitialized.Subscribe((idx, name) =>
            {
                LoggerInstance.Msg($"autotest: scene initialized: {name}");
                if (name.Contains("MainMenu") && _autotestAt < 0) _autotestAt = Environment.TickCount64 + 8000;
            });
        }
        private bool _lateFixesDone;
        public override void OnUpdate()
        {
            if (!RuntimeInformation.IsOSPlatform(OSPlatform.OSX)) return;
            MainThread.Pump();
            if (!_lateFixesDone)
            {
                _lateFixesDone = true;   // first frame: mods are loaded by now
                try { ModHelperThreadFix.TryApply(HarmonyInstance, LoggerInstance); }
                catch (Exception e) { LoggerInstance.Error($"Mod Helper thread fix failed: {e}"); }
            }
            if (_autotestAt < 0 || Environment.TickCount64 < _autotestAt) return;
            _autotestAt = long.MaxValue;
            try
            {
                var menuBase = AccessTools.TypeByName("BTD_Mod_Helper.Api.ModGameMenu");
                var mods = AccessTools.TypeByName("BTD_Mod_Helper.UI.Menus.ModsMenu");
                var open = menuBase.GetMethods(BindingFlags.Public | BindingFlags.Static).First(m => m.Name == "Open" && m.IsGenericMethodDefinition);
                LoggerInstance.Msg("autotest: opening Mods menu");
                open.MakeGenericMethod(mods).Invoke(null, new object[open.GetParameters().Length]);
                LoggerInstance.Msg("autotest: Mods menu open call returned");
            }
            catch (Exception e) { LoggerInstance.Error($"autotest failed: {e}"); }
        }

        // Debug mode only: melonfix calls this from its native crash handler so melonfix.log gets the managed stack.
        private static string _crashLogPath;

        private unsafe void RegisterCrashStackLogger()
        {
            var dbg = Environment.GetEnvironmentVariable("MELONFIX_DEBUG");
            var dir = Environment.GetEnvironmentVariable("MELONFIX_DIR");
            if (string.IsNullOrEmpty(dbg) || dbg == "0" || string.IsNullOrEmpty(dir))
                return;
            if (!TryGetMelonfixExport("melonfix_set_crash_callback", out var setter))
                return;
            _crashLogPath = Path.Combine(dir, "melonfix.log");
            ((delegate* unmanaged<delegate* unmanaged<void>, void>)setter)(&OnNativeCrash);
        }

        private static bool TryGetMelonfixExport(string name, out IntPtr export)
        {
            export = IntPtr.Zero;
            var dir = Environment.GetEnvironmentVariable("MELONFIX_DIR");
            return !string.IsNullOrEmpty(dir) &&
                   System.Runtime.InteropServices.NativeLibrary.TryLoad(Path.Combine(dir, "melonfix.dylib"), out var lib) &&
                   System.Runtime.InteropServices.NativeLibrary.TryGetExport(lib, name, out export);
        }

        [UnmanagedCallersOnly]
        private static void OnNativeCrash()
        {
            try { File.AppendAllText(_crashLogPath, Environment.StackTrace + "\n"); }
            catch { }
        }

        private unsafe void AttachICallInjector()
        {
            var injector = AccessTools.TypeByName("MelonLoader.Fixes.Il2CppInterop.Il2CppICallInjector")
                ?? throw new Exception("Il2CppICallInjector not found");
            var hook = AccessTools.Field(injector, "il2cpp_resolve_icall_hook")?.GetValue(null);
            if (hook == null)
            {
                LoggerInstance.Warning("ICall injector never got as far as creating its hook; nothing to fix");
                return;
            }

            var hookType = hook.GetType();
            if (AccessTools.Property(hookType, "IsHooked").GetValue(hook) is true)
            {
                LoggerInstance.Msg("ICall injector already active");
                return;
            }

            // Fresh, rooted delegate for the detour.
            var delegateType = injector.GetNestedType("dil2cpp_resolve_icall", BindingFlags.NonPublic)
                ?? throw new Exception("dil2cpp_resolve_icall not found");
            var detourMethod = AccessTools.Method(injector, "il2cpp_resolve_icall_Detour")
                ?? throw new Exception("il2cpp_resolve_icall_Detour not found");
            _detourKeepAlive = Delegate.CreateDelegate(delegateType, detourMethod);
            IntPtr detour = Marshal.GetFunctionPointerForDelegate(_detourKeepAlive);

            var target = (IntPtr)AccessTools.Field(hookType, "_targetHandle").GetValue(hook);
            if (target == IntPtr.Zero)
                throw new Exception("hook has no target");

            var attachDirect = AccessTools.Method(AccessTools.TypeByName("MelonLoader.InternalUtils.BootstrapInterop"), "NativeHookAttachDirect")
                ?? throw new Exception("NativeHookAttachDirect not found");
            IntPtr trampoline = target;
            attachDirect.Invoke(null, new object[] { (IntPtr)(&trampoline), detour });
            if (trampoline == target || trampoline == IntPtr.Zero)
                throw new Exception("native hook attach did not return a trampoline");

            var trampolineDelegate = Marshal.GetDelegateForFunctionPointer(trampoline, delegateType);
            AccessTools.Field(hookType, "_detourHandle").SetValue(hook, detour);
            AccessTools.Field(hookType, "_trampolineHandle").SetValue(hook, trampoline);
            AccessTools.Field(hookType, "_trampoline").SetValue(hook, trampolineDelegate);
            AccessTools.Field(hookType, "<IsHooked>k__BackingField").SetValue(hook, true);
            (AccessTools.Field(hookType, "_gcProtect")?.GetValue(null) as IList)?.Add(trampolineDelegate);

            LoggerInstance.Msg("ICall injector attached (il2cpp_resolve_icall hooked)");
        }
    }
}
