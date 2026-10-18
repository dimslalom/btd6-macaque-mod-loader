#!/bin/bash
# Cpp2IL wrapper for macOS universal (x86_64 + arm64) Unity builds. melonfix runs this instead of MelonLoader's
# Cpp2IL and passes the real binary as `--real <path>`.
# Cpp2IL can't apply chained fixups to a slice of a universal binary (read-only stream), so we hand it a thinned
# x86_64 GameAssembly plus explicit metadata path and Unity version. The thinned copy is cached in _modkit/cache and
# rebuilt whenever the game's GameAssembly.dylib is newer (game update).
HERE="$(cd "$(dirname "$0")" && pwd)"
CACHE="$HERE/cache"
REAL=""; GAMEAPP=""; ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --real) REAL="$2"; shift 2;;
    --game-path) GAMEAPP="${2//\"/}"; shift 2;;
    --exe-name) shift 2;;
    "") shift;;
    *) ARGS+=("$1"); shift;;
  esac
done
if [ -z "$REAL" ] || [ ! -x "$REAL" ]; then echo "[cpp2il-wrapper] missing --real binary"; exit 1; fi
if [ -z "$GAMEAPP" ]; then echo "[cpp2il-wrapper] no --game-path, running Cpp2IL unchanged"; exec "$REAL" "${ARGS[@]}" </dev/null; fi

SRC="$GAMEAPP/Contents/Frameworks/GameAssembly.dylib"
META="$GAMEAPP/Contents/Resources/Data/il2cpp_data/Metadata/global-metadata.dat"
UNITYVER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleGetInfoString' "$GAMEAPP/Contents/Info.plist" 2>/dev/null | sed -E 's/.*version ([0-9]+\.[0-9]+\.[0-9]+[a-z][0-9]+).*/\1/')"

# Extract the x86_64 slice from a universal (fat) Mach-O using only od + dd.
be32() { od -An -tu1 -j "$2" -N4 "$1" | awk 'NF{print ($1*16777216)+($2*65536)+($3*256)+$4; exit}'; }
thin_x86_64() {
  local src="$1" dst="$2" magic n i base cpu off size
  magic=$(be32 "$src" 0)
  if [ "$magic" != "3405691582" ]; then cp "$src" "$dst"; return $?; fi   # 0xcafebabe
  n=$(be32 "$src" 4)
  for ((i=0; i<n; i++)); do
    base=$((8 + i*20)); cpu=$(be32 "$src" $base)
    if [ "$cpu" = "16777223" ]; then                                        # CPU_TYPE_X86_64
      off=$(be32 "$src" $((base+8))); size=$(be32 "$src" $((base+12)))
      echo "[cpp2il-wrapper] x86_64 slice offset=$off size=$size"
      tail -c +$((off+1)) "$src" | head -c "$size" > "$dst.tmp" && mv "$dst.tmp" "$dst"; return $?
    fi
  done
  return 1
}
mkdir -p "$CACHE"
THIN="$CACHE/GameAssembly.x86_64.dylib"
if [ ! -f "$THIN" ] || [ "$SRC" -nt "$THIN" ]; then
  echo "[cpp2il-wrapper] thinning $SRC -> x86_64"
  thin_x86_64 "$SRC" "$THIN" || { echo "[cpp2il-wrapper] thinning failed"; exit 1; }
fi
echo "[cpp2il-wrapper] binary=$THIN unity=$UNITYVER real=$REAL"
exec "$REAL" --force-binary-path "$THIN" --force-metadata-path "$META" --force-unity-version "$UNITYVER" "${ARGS[@]}" </dev/null
