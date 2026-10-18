# Changelog

## 1.0.0

First release.

- Installs MelonLoader 0.7.3, the .NET 6 runtime and BTD6 Mod Helper next to BloonsTD6.app (the game is never modified).
- `melonfix` native bridge (v13): routes UnityPlayer's il2cpp lookups to MelonLoader, fixes the dyld image order,
  module size and hook targets on this build, runs Cpp2IL against a thinned x86_64 GameAssembly.
- `MelonMacFixes` plugin (1.2.0): SysV struct arguments in Il2CppInterop Harmony trampolines, the ICall injector,
  and Mod Helper download callbacks on the main thread.
- MacaqueLoader app: detects the setup, guides macOS folder permissions visually, installs, repairs, removes, and plays,
  with live progress for the first launch and after game updates. Universal binary; Intel Macs get a clear message.
- `macaqueloader` CLI (app, install, repair, uninstall, launch, status, logs, debug) and a Homebrew formula.
- BTD6 updates are detected on the next Play, which re-prepares mods automatically.
- Play starts Steam when it isn't running and waits for sign-in (BTD6 otherwise relaunches through Steam without mods).
