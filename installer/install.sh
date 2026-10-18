#!/bin/bash
# MacaqueLoader engine: installs MelonLoader 0.7.3 + BTD6 Mod Helper for Bloons TD 6 (Steam) on Apple Silicon Macs.
# Driven by the MacaqueLoader app and the `macaqueloader` CLI. Never modifies BloonsTD6.app.
#
# Usage: install.sh [install|uninstall|detect] [--game DIR] [--yes] [--purge]
#   install    install, or repair an existing install (keeps mods and settings)
#   uninstall  remove the mod loader (--purge also removes Mods, Plugins, UserData, UserLibs)
#   detect     print what was found, change nothing
# Output lines for the app (anything else is log text):
#   GAME <dir> | VERSION <btd6 version> | PROGRESS <0-100> <text> | WARN <text> | ERROR <code> <text> | DONE
# Error codes: no-game, intel, no-rosetta, running, no-access, download, install

INSTALLER_VERSION="dev"
ML_VERSION="0.7.3"
ML_URL="https://github.com/LavaGang/MelonLoader/releases/download/v0.7.3/MelonLoader.macOS.x64.zip"
ML_SHA256="97290f7e44670cdbfdc408796cc0136138b6bca58b75f5b98a407d24896d6607"
DOTNET_VERSION="6.0.36"
DOTNET_URL="https://builds.dotnet.microsoft.com/dotnet/Runtime/6.0.36/dotnet-runtime-6.0.36-osx-x64.tar.gz"
DOTNET_SHA256="4aa499f1e10e941bde250e1493bb4156791186790a34fb89c219e7765a9b97cd"
MODHELPER_URL="https://github.com/gurrenm3/BTD-Mod-Helper/releases/latest/download/Btd6ModHelper.dll"
KNOWN_GOOD_GAME_VERSIONS="57.2"

HERE="$(cd "$(dirname "$0")" && pwd)"
PAYLOAD="$HERE/payload"
LOGFILE="$HOME/Library/Logs/MacaqueLoader.log"
CONFIG_DIR="$HOME/Library/Application Support/macaqueloader"
mkdir -p "$(dirname "$LOGFILE")"
exec > >(tee -a "$LOGFILE") 2>&1
echo "=== macaqueloader $INSTALLER_VERSION  $(date)"

MODE="install"; GAME=""; YES=0; PURGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    install|repair) MODE=install; shift;;
    uninstall) MODE=uninstall; shift;;
    detect) MODE=detect; shift;;
    --uninstall) MODE=uninstall; shift;;
    --game) GAME="$2"; shift 2;;
    --yes|-y) YES=1; shift;;
    --purge) PURGE=1; shift;;
    --no-ui) shift;;                              # accepted for compatibility
    *) echo "unknown option: $1"; exit 2;;
  esac
done

progress() { echo "PROGRESS $1 $2"; }
warn() { echo "WARN $1"; }
fail() { echo "ERROR $1 $2"; exit 1; }
confirm() {  # only asks when run interactively without --yes
  [ "$YES" = 1 ] || [ ! -t 0 ] && return 0
  printf '%s [y/N] ' "$1"; read -r a; [ "$a" = y ] || [ "$a" = Y ]
}

# ---------- locate the game ----------
is_game_dir() { [ -d "$1/BloonsTD6.app/Contents/MacOS" ]; }
find_game() {
  local steam="$HOME/Library/Application Support/Steam" vdf lib cand
  vdf="$steam/steamapps/libraryfolders.vdf"
  { echo "$steam"
    [ -f "$vdf" ] && sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$vdf"; } | while IFS= read -r lib; do
    cand="$lib/steamapps/common/BloonsTD6"
    is_game_dir "$cand" && echo "$cand"
  done | awk '!seen[$0]++' | head -1
}
[ -z "$GAME" ] && [ "$MODE" != install ] && [ -f "$CONFIG_DIR/game-path" ] && GAME="$(cat "$CONFIG_DIR/game-path")"
[ -z "$GAME" ] && GAME="$(find_game)"
[ -n "$GAME" ] && is_game_dir "$GAME" || fail no-game "Bloons TD 6 wasn't found. Install it in Steam, or choose its folder."
GAME="$(cd "$GAME" && pwd)"
APP="$GAME/BloonsTD6.app"
BIN="$APP/Contents/MacOS/BloonsTD6"
echo "GAME $GAME"
ls "$GAME" >/dev/null 2>&1 || fail no-access "macOS is blocking access to the game folder."
GAMEVER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null)"
echo "VERSION ${GAMEVER:-unknown}"
[ "$MODE" = detect ] && { echo DONE; exit 0; }

/usr/bin/pgrep -f "$BIN" >/dev/null && fail running "Bloons TD 6 is running. Quit it first."

# ---------- uninstall ----------
if [ "$MODE" = uninstall ]; then
  confirm "Remove the mod loader from $GAME?" || exit 0
  progress 30 "Removing MelonLoader"
  rm -rf "$GAME/MelonLoader" "$GAME/dotnet" "$GAME/MelonLoader.Bootstrap.dylib" "$GAME/MelonLoader.Bootstrap.dylib.dSYM" \
         "$GAME/melonfix.dylib" "$GAME/melonfix.log" "$GAME/Plugins/MelonMacFixes.dll" \
         "$GAME/_modkit/cache" "$GAME/_modkit/cpp2il-wrapper.sh" "$GAME/_modkit/live-log.command" "$GAME/_modkit/install-info.txt" \
         "$GAME/_modkit/debug" "$GAME/_modkit/game-state" "$GAME/_modkit/known-good-versions" "$GAME/_modkit/launch.log"
  # Finder can recreate .DS_Store files while we delete; give it a second pass.
  if [ -d "$GAME/MelonLoader" ] || [ -d "$GAME/dotnet" ]; then sleep 1; rm -rf "$GAME/MelonLoader" "$GAME/dotnet"; fi
  rmdir "$GAME/_modkit" 2>/dev/null
  if [ "$PURGE" = 1 ]; then progress 70 "Removing mods"; rm -rf "$GAME/Mods" "$GAME/Plugins" "$GAME/UserData" "$GAME/UserLibs"; fi
  rm -f "$CONFIG_DIR/game-path"
  progress 100 "Removed"
  echo DONE; exit 0
fi

# ---------- preflight ----------
[ "$(uname -m)" = arm64 ] || fail intel "This Mac has an Intel processor. Only Apple Silicon Macs are supported."
/usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null || fail no-rosetta "Rosetta 2 is not installed."
case " $KNOWN_GOOD_GAME_VERSIONS " in *" ${GAMEVER%.*} "*|*" $GAMEVER "*) ;; *)
  warn "Tested with BTD6 $KNOWN_GOOD_GAME_VERSIONS; this is ${GAMEVER:-an unknown version}. Mods may need updates.";; esac
confirm "Install mods into $GAME?" || exit 0

# ---------- downloads ----------
TMP="$(mktemp -d "${TMPDIR:-/tmp}/macaqueloader.XXXXXX")" || fail install "Couldn't create a temporary folder."
trap 'rm -rf "$TMP"' EXIT
fetch() {  # url dest [sha256]
  echo "downloading $1"
  /usr/bin/curl -fsSL --retry 3 --connect-timeout 20 -o "$2" "$1" || return 1
  if [ -n "$3" ]; then
    local got; got="$(/usr/bin/shasum -a 256 "$2" | awk '{print $1}')"
    [ "$got" = "$3" ] || { echo "checksum mismatch for $1: $got"; return 1; }
  fi
}
progress 5 "Downloading MelonLoader"
fetch "$ML_URL" "$TMP/ml.zip" "$ML_SHA256" || fail download "Downloading MelonLoader failed. Check your internet connection."
progress 35 "Downloading .NET"
fetch "$DOTNET_URL" "$TMP/dotnet.tgz" "$DOTNET_SHA256" || fail download "Downloading .NET failed. Check your internet connection."
NEED_MH=0; [ -f "$GAME/Mods/Btd6ModHelper.dll" ] || NEED_MH=1
if [ "$NEED_MH" = 1 ]; then
  progress 60 "Downloading BTD6 Mod Helper"
  fetch "$MODHELPER_URL" "$TMP/Btd6ModHelper.dll" || fail download "Downloading BTD6 Mod Helper failed. Check your internet connection."
fi

# ---------- install ----------
progress 70 "Installing MelonLoader"
step() { "$@" || fail install "Installing failed at: $*"; }
cd "$GAME" || fail install "Can't enter the game folder."
step /usr/bin/unzip -oq "$TMP/ml.zip" -x 'melonloader-launch.sh' 'MelonLoader.Bootstrap.dylib.dSYM/*' -d "$GAME"
progress 80 "Installing .NET"
rm -rf "$GAME/dotnet"; step mkdir -p "$GAME/dotnet"
step /usr/bin/tar -xzf "$TMP/dotnet.tgz" -C "$GAME/dotnet"
progress 90 "Installing fixes"
step mkdir -p "$GAME/Mods" "$GAME/Plugins" "$GAME/UserData" "$GAME/UserLibs" "$GAME/_modkit"
step cp -f "$PAYLOAD/melonfix.dylib" "$GAME/melonfix.dylib"
step cp -f "$PAYLOAD/MelonMacFixes.dll" "$GAME/Plugins/MelonMacFixes.dll"
step cp -f "$PAYLOAD/cpp2il-wrapper.sh" "$PAYLOAD/live-log.command" "$GAME/_modkit/"
chmod +x "$GAME/_modkit/cpp2il-wrapper.sh" "$GAME/_modkit/live-log.command"
[ "$NEED_MH" = 1 ] && step cp -f "$TMP/Btd6ModHelper.dll" "$GAME/Mods/Btd6ModHelper.dll"

# Downloaded files must not carry quarantine flags (dyld and Gatekeeper would refuse them).
/usr/bin/xattr -dr com.apple.quarantine "$GAME/MelonLoader" "$GAME/dotnet" "$GAME/MelonLoader.Bootstrap.dylib" \
  "$GAME/melonfix.dylib" "$GAME/Plugins" "$GAME/Mods" "$GAME/_modkit" 2>/dev/null

# State for the launcher's game-update check, the CLI and the app.
echo "$KNOWN_GOOD_GAME_VERSIONS" > "$GAME/_modkit/known-good-versions"
[ -f "$GAME/_modkit/game-state" ] || echo "${GAMEVER:-unknown} $(stat -f %m "$APP/Contents/Frameworks/GameAssembly.dylib")" > "$GAME/_modkit/game-state"
mkdir -p "$CONFIG_DIR"; printf '%s\n' "$GAME" > "$CONFIG_DIR/game-path"
cat > "$GAME/_modkit/install-info.txt" <<EOF
installer=$INSTALLER_VERSION
date=$(date '+%Y-%m-%d %H:%M:%S')
game_version=$GAMEVER
melonloader=$ML_VERSION
dotnet=$DOTNET_VERSION
melonfix=$(cat "$PAYLOAD/VERSION-melonfix" 2>/dev/null)
macfixes=$(cat "$PAYLOAD/VERSION-macfixes" 2>/dev/null)
EOF

progress 100 "Installed"
echo DONE
exit 0
