#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' scripts/Info.plist)"
FINAL_APP="$PROJECT_DIR/dist/M5 File Manager.app"
if [[ -e "$FINAL_APP" ]]; then
    printf 'Build already exists: %s\nMove it aside before building another app.\n' "$FINAL_APP" >&2
    exit 1
fi
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/m5-file-manager-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
APP="$BUILD_DIR/M5 File Manager.app"
mkdir -p "$BUILD_DIR/module-cache" "$BUILD_DIR/Sources" "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Sources/*.swift "$BUILD_DIR/Sources/"
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
    BUILD_ARCHITECTURES="arm64 x86_64"
else
    BUILD_ARCHITECTURES="$(uname -m)"
fi
for BUILD_ARCH in $BUILD_ARCHITECTURES; do
    xcrun swiftc -swift-version 5 -O -target "${BUILD_ARCH}-apple-macosx14.0" \
        -module-cache-path "$BUILD_DIR/module-cache" \
        "$BUILD_DIR"/Sources/*.swift -o "$BUILD_DIR/M5FileManager-$BUILD_ARCH" \
        -framework AppKit -framework Foundation
done
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
    lipo -create "$BUILD_DIR/M5FileManager-arm64" "$BUILD_DIR/M5FileManager-x86_64" -output "$APP/Contents/MacOS/M5FileManager"
else
    cp "$BUILD_DIR/M5FileManager-$BUILD_ARCH" "$APP/Contents/MacOS/M5FileManager"
fi
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp Resources/Localizations.json "$APP/Contents/Resources/"
xcrun swift -module-cache-path "$BUILD_DIR/module-cache" scripts/make-icon.swift "$BUILD_DIR/AppIcon.iconset"
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$APP"
else
    codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
mkdir -p "$PROJECT_DIR/dist"
ditto --noextattr --norsrc "$APP" "$FINAL_APP"
for attempt in 1 2 3 4 5; do
    if codesign --verify --deep --strict "$FINAL_APP" 2>"$BUILD_DIR/verify.log"; then
        printf 'Built v%s (%s): %s\n' "$VERSION" "$BUILD_ARCHITECTURES" "$FINAL_APP"
        exit 0
    fi
    sleep 1
done
cat "$BUILD_DIR/verify.log" >&2
exit 1
