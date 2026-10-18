#!/bin/bash
# Builds all release artifacts into dist/:
#   MacaqueLoader-<v>.dmg              the app, with an Applications shortcut to drag it onto
#   MacaqueLoader-<v>.zip              the app, zipped (for people who prefer zips)
#   macaqueloader-<v>.tar.gz             CLI + engine + app, bin/ + libexec/ layout for Homebrew and manual installs
#   macaqueloader.rb                     Homebrew formula with this build's URL and sha256
#   SHA256SUMS
# Needs: Xcode Command Line Tools (clang, swiftc), a .NET 8+ SDK (`dotnet` on PATH, or DOTNET=/path/to/dotnet), curl, unzip.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(tr -d ' \n' < VERSION)"
REPO="$(sed -n 's#^repo=##p' packaging/repo.conf)"
DOTNET="${DOTNET:-dotnet}"
DIST="$ROOT/dist"; CACHE="$ROOT/.cache"; WORK="$DIST/.work"
rm -rf "$DIST"; mkdir -p "$WORK" "$CACHE"

# --- reference assemblies for MacFixes, taken from the pinned MelonLoader release (same pin as the installer) ---
ML_URL="$(sed -n 's/^ML_URL="\(.*\)"$/\1/p' installer/install.sh)"
ML_SHA256="$(sed -n 's/^ML_SHA256="\(.*\)"$/\1/p' installer/install.sh)"
REFS="$CACHE/refs-$ML_SHA256"
if [ ! -f "$REFS/MelonLoader.dll" ]; then
  echo "fetching MelonLoader reference assemblies"
  curl -fsSL --retry 3 -o "$CACHE/ml.zip" "$ML_URL"
  echo "$ML_SHA256  $CACHE/ml.zip" | shasum -a 256 -c - >/dev/null
  mkdir -p "$REFS"
  unzip -joq "$CACHE/ml.zip" 'MelonLoader/net6/MelonLoader.dll' 'MelonLoader/net6/0Harmony.dll' \
    'MelonLoader/net6/Il2CppInterop.Runtime.dll' -d "$REFS"
  rm -f "$CACHE/ml.zip"
fi

# --- native bridge (x86_64: MelonLoader's macOS build is x86_64-only, the game runs under Rosetta) ---
echo "building melonfix"
mkdir -p "$WORK/payload"
clang -arch x86_64 -mmacosx-version-min=11.0 -shared -O2 -Wall -o "$WORK/payload/melonfix.dylib" src/melonfix/melonfix.c

# --- MelonLoader plugin ---
echo "building MacFixes"
( cd src/MacFixes && python3 gen_standins.py )
DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 "$DOTNET" build src/MacFixes/MacFixes.csproj -c Release \
  -p:MLDir="$REFS" -o "$WORK/macfixes" >/dev/null
cp "$WORK/macfixes/MelonMacFixes.dll" "$WORK/payload/"

# --- engine: install.sh + payload, shared by the app and the CLI ---
ENGINE="$WORK/engine"
mkdir -p "$ENGINE"
mv "$WORK/payload" "$ENGINE/payload"
cp installer/payload/{cpp2il-wrapper.sh,launcher.sh,live-log.command} "$ENGINE/payload/"
sed -n 's#^// melonfix \(v[0-9]*\):.*#\1#p' src/melonfix/melonfix.c > "$ENGINE/payload/VERSION-melonfix"
sed -n 's#.*<Version>\(.*\)</Version>.*#\1#p' src/MacFixes/MacFixes.csproj > "$ENGINE/payload/VERSION-macfixes"
sed "s/^INSTALLER_VERSION=.*/INSTALLER_VERSION=\"$VERSION\"/" installer/install.sh > "$ENGINE/install.sh"
chmod +x "$ENGINE/install.sh" "$ENGINE/payload/"*.sh "$ENGINE/payload/live-log.command"

# --- the app (universal, so an Intel Mac at least opens it and says it's unsupported) ---
echo "building app"
APPB="$WORK/MacaqueLoader.app"
mkdir -p "$APPB/Contents/MacOS" "$APPB/Contents/Resources"
for arch in arm64 x86_64; do
  swiftc -parse-as-library -O -target "$arch-apple-macos13.0" app/Sources/*.swift -o "$WORK/app-$arch"
done
lipo -create "$WORK/app-arm64" "$WORK/app-x86_64" -output "$APPB/Contents/MacOS/MacaqueLoader"
sed "s/@VERSION@/$VERSION/g" app/Info.plist > "$APPB/Contents/Info.plist"
swift app/make-icon.swift "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$APPB/Contents/Resources/AppIcon.icns"
cp -R "$ENGINE" "$APPB/Contents/Resources/engine"
codesign --force --deep -s - "$APPB" >/dev/null

echo "packaging app"
DMGSRC="$WORK/dmg"; mkdir -p "$DMGSRC"
cp -R "$APPB" "$DMGSRC/"; ln -s /Applications "$DMGSRC/Applications"
hdiutil create -quiet -volname "MacaqueLoader" -srcfolder "$DMGSRC" -fs HFS+ -format UDZO "$DIST/MacaqueLoader-$VERSION.dmg"
( cd "$WORK" && ditto -c -k --keepParent "MacaqueLoader.app" "$DIST/MacaqueLoader-$VERSION.zip" )

# --- CLI tarball (Homebrew) ---
echo "packaging CLI"
T="$WORK/macaqueloader-$VERSION"
mkdir -p "$T/bin" "$T/libexec"
cp bin/macaqueloader "$T/bin/"; chmod +x "$T/bin/macaqueloader"
cp -R "$ENGINE/." "$T/libexec/"
cp -R "$APPB" "$T/libexec/"
echo "$VERSION" > "$T/libexec/VERSION"
cp README.md LICENSE THIRD_PARTY_NOTICES.md "$T/"
tar -C "$WORK" -czf "$DIST/macaqueloader-$VERSION.tar.gz" "macaqueloader-$VERSION"

# --- Homebrew formula for this release ---
TAR_SHA="$(shasum -a 256 "$DIST/macaqueloader-$VERSION.tar.gz" | awk '{print $1}')"
sed -e "s#@VERSION@#$VERSION#g" -e "s#@SHA256@#$TAR_SHA#g" -e "s#@REPO@#$REPO#g" \
  packaging/homebrew/macaqueloader.rb.in > "$DIST/macaqueloader.rb"

( cd "$DIST" && shasum -a 256 "MacaqueLoader-$VERSION.dmg" "MacaqueLoader-$VERSION.zip" "macaqueloader-$VERSION.tar.gz" > SHA256SUMS )
rm -rf "$WORK"
echo "done: $DIST"
ls -la "$DIST"
