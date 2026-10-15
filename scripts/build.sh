#!/bin/bash
# Builds Lisper and assembles dist/Lisper.app.
# Usage: ./scripts/build.sh [--release | --dist]
#   --release  optimised build for this Mac
#   --dist     shareable build: optimised, universal (Apple silicon + Intel), ad-hoc signed,
#              in dist/share/ (so it never replaces the dev app) and zipped to dist/Lisper.zip.
#              Set LISPER_VERSION=1.2.3 to stamp the version.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=debug
DIST=0
for arg in "$@"; do
  case "$arg" in
    --release) CONFIG=release ;;
    --dist) CONFIG=release; DIST=1 ;;
    *) echo "Unknown option: $arg (use --release or --dist)" >&2; exit 1 ;;
  esac
done

if [[ $DIST == 1 ]]; then
  # One build per architecture, then lipo: `swift build --arch a --arch b` needs xcbuild,
  # which a Command-Line-Tools-only Mac doesn't have.
  swift build -c release --arch arm64 --product Lisper
  swift build -c release --arch x86_64 --product Lisper
  BIN_DIR=".build/arm64-apple-macosx/release"
  BIN=".build/Lisper-universal"
  lipo -create -output "$BIN" "$BIN_DIR/Lisper" ".build/x86_64-apple-macosx/release/Lisper"
else
  swift build -c "$CONFIG" --product Lisper
  BIN_DIR=".build/$CONFIG"
  BIN="$BIN_DIR/Lisper"
fi

APP="dist/Lisper.app"
[[ $DIST == 1 ]] && APP="dist/share/Lisper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Lisper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -n "${LISPER_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $LISPER_VERSION" "$APP/Contents/Info.plist"
fi
# Bundle any SPM resource bundles (GRDB etc.) if present
find "$BIN_DIR" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \; 2>/dev/null || true
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

IDENTITY="Lisper Dev"
if [[ $DIST == 1 ]]; then
  # Ad-hoc for anything shared: "Lisper Dev" is a self-signed cert that only this Mac trusts.
  codesign --force --sign - "$APP"
  echo "Ad-hoc signed for distribution"
# Attempt the identity signature directly: an untrusted self-signed cert signs fine
# and gives a stable designated requirement (TCC grants survive rebuilds), but
# `find-identity -v` would hide it because it only lists trusted identities.
elif codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null; then
  echo "Signed with $IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "Ad-hoc signed (run scripts/make-cert.sh once so permissions survive rebuilds)"
fi
echo "Built $APP"

if [[ $DIST == 1 ]]; then
  rm -f dist/Lisper.zip
  ditto -c -k --sequesterRsrc --keepParent "$APP" dist/Lisper.zip
  echo "Packaged dist/Lisper.zip"
fi
