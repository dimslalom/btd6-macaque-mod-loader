# Design notes

Why stock MelonLoader 0.7.3 doesn't work for BTD6 on Apple Silicon, and what this project does about each problem.
Environment when this was worked out: BTD6 57.2 (build 12199), Unity 6000.3.23f1, IL2CPP, universal (x86_64 + arm64)
app, MelonLoader 0.7.3 macOS x64, Il2CppInterop 1.5.1-ci.845, BTD6 Mod Helper 3.6.9.

## Launch model

MelonLoader's macOS build is x86_64 only, so the game runs its x86_64 slice under Rosetta:

```
arch -x86_64 -e DYLD_INSERT_LIBRARIES=melonfix.dylib:MelonLoader.Bootstrap.dylib ... BloonsTD6.app/Contents/MacOS/BloonsTD6
```

`BloonsTD6.app` is signed with `allow-dyld-environment-variables` and `disable-library-validation`, so injection works
without re-signing. Nothing inside the app bundle is changed. `melonfix.dylib` is injected first.

## melonfix (native, `src/melonfix/melonfix.c`)

1. **plthook writes land at the wrong address.** MelonLoader hooks UnityPlayer's `dlsym`, `fopen`, `vfprintf`, `dup2`
   through plthook, which reports success but writes to the correct `__got` slot plus a constant delta (0x4000 here),
   so Unity's `dlsym("il2cpp_init")` never reaches MelonLoader. melonfix interposes `dlsym`, snapshots non-system
   `__DATA` segments at startup, finds the four `__got` slots through the indirect symbol table, locates the delta
   where all four misplaced writes landed, and routes UnityPlayer's `dlsym` calls through MelonLoader's detour.
2. **dyld image 0 isn't the game.** With `DYLD_INSERT_LIBRARIES`, image 0 is the first injected library, but
   MelonLoader's ProcessModulesFix assumes it's the executable. melonfix answers `dlsym` for
   `_dyld_get_image_name/_header/_vmaddr_slide` with wrappers that swap the executable to index 0.
3. **Child processes inherit the injection.** The constructor clears `DYLD_INSERT_LIBRARIES` after dyld has read it,
   so Cpp2IL starts clean.
4. **Cpp2IL can't read a slice of a universal Mach-O** (it applies chained fixups to a read-only stream). melonfix
   interposes `execve`/`posix_spawn` and runs MelonLoader's Cpp2IL through `cpp2il-wrapper.sh`, which extracts the
   x86_64 slice into `_modkit/cache` (re-extracted when the game binary changes) and passes explicit paths. Redirecting
   at exec time keeps working when MelonLoader re-downloads Cpp2IL.
5. **Il2CppInterop maps the universal file** while Cpp2IL's offsets refer to the thin one. melonfix redirects read-only
   `open()` calls for `GameAssembly.dylib` coming from .NET to the thin copy.
6. **Module size overshoots.** ProcessModulesFix sizes a module as header + load commands + sum of segment sizes, about a
   page past the real end. Il2CppInterop's signature scan reads to that end and faults once the neighbouring mapping is
   unmapped. melonfix hands ProcessModulesFix an adjusted header copy for GameAssembly so the size is exact.
7. **Il2CppInterop hooks the wrong functions.** Its signatures are for Windows builds, and its xref fallbacks land on
   neighbours on this build: `BlobReader::GetConstantValueFromBlob` instead of `Class::GetFieldDefaultValue`, and
   `GlobalMetadata::GetAssemblyTypeHandle` instead of `GetTypeInfoFromTypeDefinitionIndex`. GameAssembly ships full local
   symbols, so melonfix wraps MelonLoader's `NativeHookAttach` and retargets those hooks by symbol name.
8. **`dlopen("GameAssembly.dylib")`** with a bare name only searches `DYLD_LIBRARY_PATH`; melonfix resolves it to the
   copy in `Contents/Frameworks`.
9. **Debug aids** (`MELONFIX_DEBUG=1`): verbose log, and a crash handler that logs a native backtrace with GameAssembly
   symbol names plus, through a callback registered by MacFixes, the managed stack.

## MelonMacFixes (managed plugin, `src/MacFixes`)

1. **SysV struct arguments.** Il2CppInterop's Harmony backend builds a native-to-managed trampoline per patched method
   and assumes non-blittable struct arguments (`Il2CppSystem.ValueType` wrappers such as `StreamingContext` or
   `AsyncOperationHandle<T>`) arrive as a pointer, which is the Windows x64 rule. On macOS they arrive by value: in one
   or two registers up to 16 bytes, otherwise copied to the stack. The trampoline then boxes garbage and the game
   crashes (Mod Helper patches `ProfileModel.Validate` and `ResourceLoader.OnSpriteLoaded`, both affected). The plugin
   transpiles `Il2CppDetourMethodPatcher` so such parameters are declared as blittable stand-in structs with the same
   size and SysV classification (`StandIns.g.cs`), and are boxed from their address (`ldarga`), the same path
   Il2CppInterop already uses on 32-bit. It runs in `OnPreModsLoaded`, before any mod patches. Without the plugin,
   melonfix refuses those hooks instead of crashing.
2. **ICall injector.** MelonLoader attaches its `il2cpp_resolve_icall` hook through a sanity check that calls ClrMD's
   `CreateSnapshotAndAttach`, which throws on macOS, so Unity icalls the game itself doesn't use stay unresolved.
   MelonLoader shields its own methods from Harmony, so the plugin completes the half-built hook itself through
   `NativeHookAttachDirect`.
3. **Mod Helper download callbacks.** `ModHelperGithub.Download` runs its UI callback after an `await` with no
   synchronization context, on a thread-pool thread; toggling UI there races Unity's canvas update ("Collection was
   modified" in `RectMask2D.PerformClipping`). The plugin marshals that callback onto the main thread.

## The app and macOS permissions

`MacaqueLoader.app` (SwiftUI, `app/`) is the front end; `installer/install.sh` and `installer/payload/launcher.sh` are the
engine, shared with the `macaqueloader` CLI. The app runs them as child processes and reads their `PROGRESS` / `ERROR` /
`STATE` lines.

macOS privacy protection (TCC) guards Documents, Desktop, Downloads, iCloud Drive and external drives. Steam's default
library (`~/Library/Application Support/Steam`) isn't protected, so most people never see a permission step. When the
library is protected:

- Access is granted to the *responsible app*, which is MacaqueLoader: the engine scripts and the game it starts run as its
  children, so one grant covers install, repair and play.
- The app's Info.plist carries the folder usage descriptions, so macOS shows its standard prompt. Before that, the app
  shows a replica of the prompt with "Allow" pointed out.
- If access was denied, the app shows an animated mini System Settings (the switch in Files & Folders, or dragging the
  app into Full Disk Access when it isn't listed), opens that page, and polls until access works.
- What didn't work: a bash-script launcher app (no usage descriptions, background-only) got denied silently with no
  prompt, and an ad-hoc signature changes with every build, so a script app's grant didn't survive reinstalls. Starting
  the game through LaunchServices (`open --env`) to avoid the launcher needing access fails, because MelonLoader then
  can't find its bootstrap without `DYLD_LIBRARY_PATH`, which LaunchServices won't pass.
- The app is ad-hoc signed, so macOS asks again after an app update. Gatekeeper blocks the first open of a downloaded
  copy (System Settings > Open Anyway); the Homebrew route (`macaqueloader app`) avoids that, because Homebrew's downloads
  aren't quarantined.

## Launching

`launcher.sh` starts the game itself (not through Steam) with the DYLD variables and the game folder as working
directory. Steam has to be running and signed in first: a Steam game started while Steam is closed asks Steam to start
and relaunch it, then quits, and Steam's relaunch doesn't carry the mod loader. So when Steam isn't running, the
launcher starts it and waits for `[Logged On` in `logs/connection_log.txt` (at most 60 seconds: Steam prunes its logs,
so this is a hint, not a requirement). When Steam is already running it goes ahead. If the game still quits within
30 seconds without `SteamAPI_Init(): Loaded` in its output, the app asks the user to sign in to Steam and press Play
again.

## Known gaps

- Il2CppInterop's `DelegateSupport` and `ClassInjector` trampolines have the same struct-argument assumption as (1).
  Nothing in Mod Helper hits them today; a mod that passes non-blittable structs through injected delegates or classes
  could.
- Small non-blittable struct *return* values (16 bytes or less) in Harmony patches are still handled the Windows way.

## Updates

- **BTD6 update:** only `BloonsTD6.app` changes. The launcher records the game version and GameAssembly timestamp in
  `_modkit/game-state` and notifies on change; MelonLoader regenerates assemblies (hash check), the wrapper re-thins
  GameAssembly (timestamp check), Mod Helper's UpdaterPlugin fetches a matching Mod Helper. melonfix locates
  everything at runtime (delta scan, symbol names).
- **MelonLoader:** pinned to 0.7.3 because melonfix depends on its internals (plthook behaviour, `NativeHookAttach`
  export, ProcessModulesFix). A new MelonLoader version needs re-testing before the pin moves.
