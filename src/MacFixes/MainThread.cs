using System;
using System.Collections.Concurrent;
using System.Threading;
using HarmonyLib;

namespace MelonMacFixes
{
    // Runs work on Unity's main thread. Drained from MacFixes.OnUpdate.
    internal static class MainThread
    {
        private static readonly ConcurrentQueue<Action> Queue = new();
        private static int _mainThreadId = -1;

        public static bool IsMain => Thread.CurrentThread.ManagedThreadId == _mainThreadId;

        public static void Run(Action action)
        {
            if (IsMain) action();
            else Queue.Enqueue(action);
        }

        public static void Pump()
        {
            _mainThreadId = Thread.CurrentThread.ManagedThreadId;
            while (Queue.TryDequeue(out var action))
            {
                try { action(); }
                catch (Exception e) { MelonLoader.MelonLogger.Error($"[MelonMacFixes] main-thread callback: {e}"); }
            }
        }
    }

    // Mod Helper's ModHelperGithub.Download invokes its filePath callback after an await with no
    // SynchronizationContext, i.e. on a thread-pool thread. The Mod Browser's callback toggles UI
    // (Download/Installed icons) with SetActive, which races Unity's main-thread canvas update and throws
    // "Collection was modified" in RectMask2D.PerformClipping. Marshal that callback onto the main thread.
    internal static class ModHelperThreadFix
    {
        private static bool _applied;

        public static void TryApply(HarmonyLib.Harmony harmony, MelonLoader.MelonLogger.Instance log)
        {
            if (_applied) return;
            _applied = true;
            var download = AccessTools.Method("BTD_Mod_Helper.Api.Internal.ModHelperGithub:Download");
            if (download == null)
            {
                log.Msg("Mod Helper download thread fix: ModHelperGithub.Download not found, skipped");
                return;
            }
            harmony.Patch(download, prefix: new HarmonyMethod(typeof(ModHelperThreadFix), nameof(Prefix)));
            log.Msg("Mod Helper download callbacks now run on the main thread");
        }

        private static void Prefix(ref Action<string> callback)
        {
            var inner = callback;
            if (inner == null) return;
            callback = path => MainThread.Run(() => inner(path));
        }
    }
}
