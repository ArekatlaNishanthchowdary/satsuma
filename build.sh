#!/bin/bash
# ./build.sh          → build/Satsuma.app
# ./build.sh --dmg    → also dist/Satsuma-<version>.dmg
# ARCH=arm64 ./build.sh for Apple Silicon (default x86_64, i.e. Intel).
set -euo pipefail
cd "$(dirname "$0")"

ARCH="${ARCH:-x86_64}"
APP=build/Satsuma.app
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"

swift build -c release --arch "$ARCH"
BIN="$(swift build -c release --arch "$ARCH" --show-bin-path)/Satsuma"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Satsuma"
cp Resources/Info.plist "$APP/Contents/Info.plist"
swift Tools/MakeIcon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "✓ $APP ($(lipo -archs "$APP/Contents/MacOS/Satsuma"))"

if [[ "${1:-}" == "--dmg" ]]; then
    mkdir -p build/dmg dist
    cp -R "$APP" build/dmg/
    ln -s /Applications build/dmg/Applications
    hdiutil create -volname Satsuma -srcfolder build/dmg -ov -format UDZO "dist/Satsuma-$VERSION.dmg" >/dev/null
    echo "✓ dist/Satsuma-$VERSION.dmg"
fi
