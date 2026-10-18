# Third-party software

This project contains no third-party code or binaries. The installer downloads these at install time, from their
official release pages, and verifies pinned checksums where noted:

| Component | Version | License | Source |
|---|---|---|---|
| MelonLoader (macOS x64) | 0.7.3, checksum-pinned | Apache-2.0 | https://github.com/LavaGang/MelonLoader |
| .NET runtime (osx-x64) | 6.0.36, checksum-pinned | MIT | https://dotnet.microsoft.com |
| BTD6 Mod Helper | latest release | GPL-3.0 | https://github.com/gurrenm3/BTD-Mod-Helper |
| Cpp2IL (downloaded by MelonLoader) | as chosen by MelonLoader | MIT | https://github.com/SamboyCoding/Cpp2IL |

The MacFixes plugin is compiled against MelonLoader, HarmonyX and Il2CppInterop reference assemblies, which the build
script extracts from the pinned MelonLoader release (they are not committed here). Il2CppInterop is LGPL-3.0;
HarmonyX is MIT.

Bloons TD 6 is a trademark of Ninja Kiwi. This project is not affiliated with or endorsed by Ninja Kiwi.
