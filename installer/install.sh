#!/bin/bash
# MacaqueLoader engine: installs MelonLoader 0.7.3 + BTD6 Mod Helper for Bloons TD 6 (Steam) on Apple Silicon Macs.
# Driven by the MacaqueLoader app and the `macaqueloader` CLI. Never modifies BloonsTD6.app.
#
# Usage: install.sh [install|uninstall|detect] [--game DIR] [--yes] [--purge]
#   install    install, or repair an existing install (keeps mods and settings)
#   uninstall  remove the mod loader (--purge also removes Mods, Plugins, UserData, UserLibs, Btd6ModHelper)
#   detect     print what was found, change nothing
# Output lines for the app (anything else is log text):
#   GAME <dir> | VERSION <btd6 version> | PROGRESS <0-100> <text> | WARN <text> | ERROR <code> <text> | DONE
# Error codes: no-game, intel, no-rosetta, running, no-access, download, checksum, install

INSTALLER_VERSION="dev"
ML_VERSION="0.7.3"
ML_URL="https://github.com/LavaGang/MelonLoader/releases/download/v0.7.3/MelonLoader.macOS.x64.zip"
ML_SHA256="97290f7e44670cdbfdc408796cc0136138b6bca58b75f5b98a407d24896d6607"
DOTNET_VERSION="6.0.36"
DOTNET_URL="https://builds.dotnet.microsoft.com/dotnet/Runtime/6.0.36/dotnet-runtime-6.0.36-osx-x64.tar.gz"
DOTNET_SHA256="4aa499f1e10e941bde250e1493bb4156791186790a34fb89c219e7765a9b97cd"
MODHELPER_VERSION="3.6.10"
MODHELPER_URL="https://github.com/gurrenm3/BTD-Mod-Helper/releases/download/3.6.10/Btd6ModHelper.dll"
MODHELPER_SHA256="59714e5d2da68f80d752ccba3c8645221bfc78367f221e0ee5d9c45a5778c0aa"
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
    --game) [ $# -ge 2 ] || { echo "--game needs a folder"; exit 2; }; GAME="$2"; shift 2;;
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
  printf '%s [y/N] ' "$1" > /dev/tty; read -r a;   # stdout may be filtered line by line, which would hide the prompt
  [ "$a" = y ] || [ "$a" = Y ]
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
[ -z "$GAME" ] && [ -f "$CONFIG_DIR/game-path" ] && is_game_dir "$(cat "$CONFIG_DIR/game-path")" && GAME="$(cat "$CONFIG_DIR/game-path")"
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

# pgrep -f takes a regex: escape the path so folders like "Games (1)" match literally.
game_running() { /usr/bin/pgrep -f -- "$(printf '%s' "$BIN" | sed 's/[][\.*^$+?(){}|]/\\&/g')" >/dev/null; }
game_running && fail running "Bloons TD 6 is running. Quit it first."

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
  if [ "$PURGE" = 1 ]; then
    progress 70 "Removing mods"
    rm -rf "$GAME/Mods" "$GAME/Plugins" "$GAME/UserData" "$GAME/UserLibs" "$GAME/Btd6ModHelper"
    rmdir "$GAME/Jukebox" 2>/dev/null                 # may hold the user's own music, so only when empty
  fi
  rm -f "$CONFIG_DIR/game-path"; rmdir "$CONFIG_DIR" 2>/dev/null
  progress 100 "Removed"
  echo DONE; exit 0
fi

# ---------- preflight ----------
# Not uname -m: it says x86_64 in a shell running under Rosetta.
[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] || fail intel "This Mac has an Intel processor. Only Apple Silicon Macs are supported."
/usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null || fail no-rosetta "Rosetta 2 is not installed."
case "$GAME" in *:*) fail install "The game folder path contains a colon, which the launcher can't pass to dyld: $GAME";; esac
case " $KNOWN_GOOD_GAME_VERSIONS " in *" ${GAMEVER%.*} "*|*" $GAMEVER "*) ;; *)
  warn "Tested with BTD6 $KNOWN_GOOD_GAME_VERSIONS; this is ${GAMEVER:-an unknown version}. Mods may need updates.";; esac
confirm "Install mods into $GAME?" || exit 0

# ---------- downloads ----------
TMP="$(mktemp -d "${TMPDIR:-/tmp}/macaqueloader.XXXXXX")" || fail install "Couldn't create a temporary folder."
trap 'rm -rf "$TMP"' EXIT
fetch() {  # what url dest sha256: downloads and verifies; a mismatch is its own error, never "check your connection"
  echo "downloading $2"
  /usr/bin/curl -fsSL --retry 3 --connect-timeout 20 -o "$3" "$2" || fail download "Downloading $1 failed. Check your internet connection."
  local got; got="$(/usr/bin/shasum -a 256 "$3" | awk '{print $1}')"
  if [ "$got" != "$4" ]; then
    echo "checksum mismatch for $2: got $got, expected $4"; rm -f "$3"
    fail checksum "The downloaded $1 doesn't match its expected checksum, so it wasn't installed. Try again later; if it keeps happening, report it."
  fi
}
progress 5 "Downloading MelonLoader"
fetch MelonLoader "$ML_URL" "$TMP/ml.zip" "$ML_SHA256"
progress 35 "Downloading .NET"
fetch .NET "$DOTNET_URL" "$TMP/dotnet.tgz" "$DOTNET_SHA256"
NEED_MH=0; [ -f "$GAME/Mods/Btd6ModHelper.dll" ] || NEED_MH=1
if [ "$NEED_MH" = 1 ]; then
  progress 60 "Downloading BTD6 Mod Helper"
  fetch "BTD6 Mod Helper" "$MODHELPER_URL" "$TMP/Btd6ModHelper.dll" "$MODHELPER_SHA256"
fi

# ---------- install ----------
progress 70 "Installing MelonLoader"
step() { "$@" || fail install "Installing failed at: $*"; }
cd "$GAME" || fail install "Can't enter the game folder."
# Written again at the end, so an interrupted install or repair shows up as needing an update.
rm -f "$GAME/_modkit/install-info.txt"
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

# The files we just installed must not carry quarantine flags (dyld and Gatekeeper would refuse them). Only those:
# the user's own Mods and Plugins are left as they are.
/usr/bin/xattr -dr com.apple.quarantine "$GAME/MelonLoader" "$GAME/dotnet" "$GAME/MelonLoader.Bootstrap.dylib" \
  "$GAME/melonfix.dylib" "$GAME/Plugins/MelonMacFixes.dll" "$GAME/_modkit/cpp2il-wrapper.sh" "$GAME/_modkit/live-log.command" 2>/dev/null
[ "$NEED_MH" = 1 ] && /usr/bin/xattr -d com.apple.quarantine "$GAME/Mods/Btd6ModHelper.dll" 2>/dev/null

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
modhelper=$MODHELPER_VERSION
melonfix=$(cat "$PAYLOAD/VERSION-melonfix" 2>/dev/null)
macfixes=$(cat "$PAYLOAD/VERSION-macfixes" 2>/dev/null)
EOF

progress 100 "Installed"
echo DONE
exit 0
