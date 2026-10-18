#!/bin/bash
# Starts BTD6 (Apple Silicon, via Rosetta) with MelonLoader injected. Used by the MacaqueLoader app and `macaqueloader launch`.
# Usage: launcher.sh [<game folder>]   (default: the folder recorded by the installer)
# Output, one per line, for the app to read:
#   STATE <version> <updated:0|1> <tested:0|1>    game version, whether it changed since the last modded launch
#   STARTED <pid> | RUNNING <pid> | ERROR <message>
# Debug mode (file _modkit/debug in the game folder): verbose melonfix.log with crash backtraces.

CONFIG="$HOME/Library/Application Support/macaqueloader/game-path"
GAME="${1:-}"
[ -z "$GAME" ] && [ -f "$CONFIG" ] && GAME="$(cat "$CONFIG")"
APP="$GAME/BloonsTD6.app"
BIN="$APP/Contents/MacOS/BloonsTD6"
LOG="$GAME/_modkit/launch.log"

fail() { echo "ERROR $1"; exit 1; }
[ -n "$GAME" ] || fail "not installed"
ls "$GAME" >/dev/null 2>&1 || fail "no access to the game folder"
[ -x "$BIN" ] || fail "BloonsTD6.app not found in $GAME"
[ -f "$GAME/melonfix.dylib" ] && [ -f "$GAME/MelonLoader.Bootstrap.dylib" ] || fail "mod files missing, repair needed"

pid="$(/usr/bin/pgrep -f "$BIN" | head -1)"
if [ -n "$pid" ]; then echo "RUNNING $pid"; /usr/bin/open -a "$APP"; exit 0; fi

# BTD6 updates: Steam only replaces BloonsTD6.app, the mod files next to it keep working. On the first launch after
# an update MelonLoader regenerates its assemblies and the Cpp2IL wrapper re-thins GameAssembly (1 to 3 minutes).
GA="$APP/Contents/Frameworks/GameAssembly.dylib"
STATE="$GAME/_modkit/game-state"
NOWV="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null)"
NOWM="$(/usr/bin/stat -f %m "$GA" 2>/dev/null)"
UPDATED=0
if [ -f "$STATE" ]; then
  read -r _ OLDM < "$STATE"
  [ "$OLDM" != "$NOWM" ] && UPDATED=1
fi
TESTED=1
if [ -f "$GAME/_modkit/known-good-versions" ] && ! grep -qwE -- "${NOWV%.*}|$NOWV" "$GAME/_modkit/known-good-versions"; then
  TESTED=0
fi
mkdir -p "$GAME/_modkit"; echo "${NOWV:-unknown} ${NOWM:-0}" > "$STATE"
echo "STATE ${NOWV:-unknown} $UPDATED $TESTED"

# Steam must be running and signed in first. Started on its own while Steam is closed, BTD6 asks Steam to start and
# relaunch it, then quits, and Steam's relaunch doesn't load mods. If Steam is already running we go ahead (it restores
# the sign-in itself). If we start it, we wait for "[Logged On" in its connection log; Steam prunes its logs, so that's
# only a hint: after 60 seconds we go ahead anyway, and the app explains if the game then can't reach Steam.
CLOG="$HOME/Library/Application Support/Steam/logs/connection_log.txt"
steam_running() { /usr/bin/pgrep -x steam_osx >/dev/null; }
# Last connection state Steam logged after byte offset $1 (empty if the log doesn't exist).
steam_state() { tail -c +"$(( $1 + 1 ))" "$CLOG" 2>/dev/null | grep -oE '^\[[0-9: -]+\] \[(Logged On|Logged Off|Logging On|Logging Off|Connecting|Connected|Disconnected)' | tail -1 | sed 's/.*\[//'; }
if ! steam_running; then
  echo "STEAM starting"
  FROM="$(/usr/bin/stat -f %z "$CLOG" 2>/dev/null || echo 0)"
  /usr/bin/open -g -a Steam 2>/dev/null || /usr/bin/open -g "steam://open/main" 2>/dev/null || fail "Steam isn't installed"
  for _ in $(seq 1 30); do steam_running && break; sleep 1; done
  steam_running || fail "Steam didn't start"
  waited=0
  until [ "$(steam_state "$FROM")" = "Logged On" ] || [ "$waited" -ge 60 ]; do
    [ "$waited" = 8 ] && echo "STEAM sign-in"          # taking long: probably waiting for the user to sign in
    steam_running || fail "Steam was closed"
    sleep 1; waited=$((waited + 1))
  done
  sleep 3                                              # give a freshly started Steam a moment to finish loading
fi
echo "STEAM ready"

DEBUG=0; [ -f "$GAME/_modkit/debug" ] && DEBUG=1
INSERT="$GAME/melonfix.dylib:$GAME/MelonLoader.Bootstrap.dylib"
{
  echo "[launcher] $(date)  game=$GAME  btd6=${NOWV:-?}  updated=$UPDATED  debug=$DEBUG"
  echo "[launcher] DYLD_INSERT_LIBRARIES=$INSERT"
} > "$LOG" 2>&1
rm -f "$GAME/melonfix.log"

cd "$GAME" || fail "can't enter the game folder"
# DYLD_LIBRARY_PATH: MelonLoader's managed side loads its bootstrap by bare name.
nohup /usr/bin/arch -x86_64 \
  -e DYLD_INSERT_LIBRARIES="$INSERT" \
  -e DYLD_LIBRARY_PATH="$GAME" \
  -e MELONFIX_DIR="$GAME" \
  -e MELONFIX_DEBUG="$DEBUG" \
  -e DOTNET_ROOT="$GAME/dotnet" \
  "$BIN" >> "$LOG" 2>&1 &
echo "STARTED $!"
exit 0
