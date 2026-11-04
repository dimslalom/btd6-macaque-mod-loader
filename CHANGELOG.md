# Changelog

## Unreleased

Security and robustness pass (no new features):

- BTD6 Mod Helper is pinned to 3.6.10 with a verified SHA-256, like MelonLoader and .NET. A checksum mismatch is its own
  error (`checksum`) and the file is discarded; it is no longer reported as a connection problem.
- The app never elevates: the Rosetta screen shows the one-line Terminal command and waits, instead of running
  `softwareupdate` as root through an admin prompt. `NSAppleEventsUsageDescription` is gone.
- Full Disk Access is never suggested; only the per-folder Files & Folders switch.
- No self-dequarantine: the "Move to Applications" banner and the `xattr` on the copied app are removed (`macaqueloader
  app` just copies). The installer strips quarantine only from the files it installs, not from `Mods/` or `Plugins/`.
- A MacaqueLoader version mismatch shows an Update button instead of re-downloading silently.
- Uninstall also removes the app's preferences and the empty `~/Library/Application Support/macaqueloader` folder.
- melonfix v14: the dlsym-hook scan now accepts a lone misplaced hook (MelonLoader only installs its fopen/dup2/vfprintf
  hooks when player-log capture is on, so the old "two other hooks at the same delta" rule never matched and the first
  changed data word was called instead, crashing the game; verified on BTD6 57.4). A scanned detour candidate must be
  executable before it is called; symbol retargets skip `.cold.`
  fragments, accept every overload of the wrong function and require a unique right one; the method map can't spin
  when full; lazily built state is mutex-protected.
- Scripts: `pgrep` patterns are escaped (paths with `(`, `+`, `[` …), game folders containing `:` are refused, the
  launcher's "tested version" rule matches the installer and the app, `_modkit/game-state` is written only once the game
  starts, Cpp2IL children get no `DYLD_*` variables.
- GitHub Actions are pinned by commit SHA.

Fixes:

- CLI: the `[y/N]` prompt of `install` and `uninstall` was never shown, so both looked frozen without `--yes`. `repair`
  and `install` now use the saved game folder, a stale saved folder falls back to searching Steam, `--game` without a
  value is an error instead of an endless loop, and the Apple Silicon check works in a shell running under Rosetta.
- `--purge` and "Remove everything" also delete `Btd6ModHelper/` (mod settings), and `Jukebox/` when it is empty.
- An interrupted install or repair now shows as needing an update, and the app can't be closed while one is running.
- The first launch after a game update no longer reads the previous session's log, which skipped the Preparing screen.
- Without Mod Helper the Preparing screen finishes, instead of reporting a normal quit as a crash.
- Uninstalling from the app really leaves no preferences behind, and keeps them if the uninstall didn't run.
- A double click on Play can't start two launchers, and attaching to a running game no longer reuses an old process ID.
- The Cpp2IL wrapper re-thins GameAssembly when its timestamp changes in either direction (a rollback could keep a stale
  copy).
- melonfix v15: a disabled retarget no longer disables the ones after it, the "detour NOT found" log line prints the
  real count, hooks only walk the symbol table in debug mode, and the log can't overwrite the managed crash stack.
- BTD6 57.4 is on the tested list. CI runs shellcheck at `warning`, as `CONTRIBUTING.md` says.

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
