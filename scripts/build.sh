#!/bin/bash
# Builds "WOL Menubar.app" (universal: Apple Silicon + Intel).
#   scripts/build.sh            → build/WOL Menubar.app
#   scripts/build.sh --install  → also copies it to /Applications and starts it
#   scripts/build.sh --zip      → also creates build/WOL-Menubar-<version>.zip for a release
# Needs only the Xcode Command Line Tools (xcode-select --install), not Xcode.
set -euo pipefail

VERSION="1.0.3"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/WOL Menubar.app"
SOURCES=("$ROOT"/Sources/WOLMenubar/*.swift)

cd "$ROOT"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ Compiling …"
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target "$arch-apple-macos13.0" "${SOURCES[@]}" -o "$BUILD/WOLMenubar-$arch"
done
lipo -create "$BUILD/WOLMenubar-arm64" "$BUILD/WOLMenubar-x86_64" -output "$APP/Contents/MacOS/WOLMenubar"
rm "$BUILD"/WOLMenubar-arm64 "$BUILD"/WOLMenubar-x86_64

sed "s/__VERSION__/$VERSION/g" Resources/Info.plist >"$APP/Contents/Info.plist"

if [ ! -f Resources/AppIcon.icns ]; then
  echo "→ Rendering icon …"
  ICONSET="$BUILD/AppIcon.iconset"; mkdir -p "$ICONSET"
  swift scripts/make-icon.swift "$BUILD/icon.png"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$BUILD/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$BUILD/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
  rm -rf "$ICONSET" "$BUILD/icon.png"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Ad-hoc signature (required on Apple Silicon; not notarized)
codesign --force --sign - "$APP"
echo "✓ Built $APP"

for arg in "$@"; do
  case "$arg" in
    --install)
      install_stage="$(mktemp -d /Applications/.WOL-Menubar-install.XXXXXX)"
      restore_previous() {
        if [ -e "$install_stage/previous.app" ] && [ ! -e "/Applications/WOL Menubar.app" ]; then
          mv "$install_stage/previous.app" "/Applications/WOL Menubar.app" || true
        fi
        if [ -e "$install_stage/previous.app" ]; then
          echo "Previous app retained at $install_stage/previous.app" >&2
        else
          rm -rf "$install_stage"
        fi
      }
      trap restore_previous EXIT
      ditto "$APP" "$install_stage/WOL Menubar.app"
      codesign --verify "$install_stage/WOL Menubar.app"
      if [ -e "/Applications/WOL Menubar.app" ]; then
        mv "/Applications/WOL Menubar.app" "$install_stage/previous.app"
      fi
      mv "$install_stage/WOL Menubar.app" "/Applications/WOL Menubar.app"
      rm -rf "$install_stage/previous.app"
      trap - EXIT
      rm -rf "$install_stage"
      pkill -x WOLMenubar 2>/dev/null && sleep 1 || true
      open "/Applications/WOL Menubar.app"
      echo "✓ Installed to /Applications and started" ;;
    --zip)
      (cd "$BUILD" && ditto -c -k --keepParent "WOL Menubar.app" "WOL-Menubar-$VERSION.zip")
      echo "✓ $BUILD/WOL-Menubar-$VERSION.zip" ;;
  esac
done
