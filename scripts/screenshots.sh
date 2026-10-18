#!/bin/bash
# Renders every app screen (light + dark) from the real SwiftUI views, without screen-recording permission.
#   scripts/screenshots.sh [out-dir]   -> dist/screenshots (plain) and dist/screenshots/framed (window-framed, GIFs)
#   scripts/screenshots.sh --readme    -> also refreshes the images the README uses, in docs/readme
# SNAPSHOT_GAME_APP=/path/to/BloonsTD6.app uses the real game icon; otherwise a neutral placeholder.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
README=0; OUT="$ROOT/dist/screenshots"
for a in "$@"; do case "$a" in --readme) README=1;; *) OUT="$a";; esac; done
BIN="$ROOT/.cache/snapshots"
mkdir -p "$ROOT/.cache"
swiftc -D SNAPSHOTS -parse-as-library -target "$(uname -m)-apple-macos13.0" "$ROOT"/app/Sources/*.swift "$ROOT/app/snapshots/Snapshots.swift" -o "$BIN"
rm -rf "$OUT"; cd "$ROOT" && "$BIN" "$OUT"
echo "screenshots in $OUT"

if [ "$README" = 1 ]; then
  R="$ROOT/docs/readme"; mkdir -p "$R"
  for n in 8-home 6-install 4-ask-access 9-preparing 9b-steam 3-rosetta; do
    for m in light dark; do cp "$OUT/framed/$n-$m.png" "$R/${n#*-}-$m.png"; done
  done
  cp "$OUT/framed/permission-light.gif" "$OUT/framed/permission-dark.gif" "$R/"
  ICONSET="$ROOT/.cache/AppIcon.iconset"
  swift "$ROOT/app/make-icon.swift" "$ICONSET"
  cp "$ICONSET/icon_128x128@2x.png" "$R/icon.png"
  echo "README images in $R"
fi
