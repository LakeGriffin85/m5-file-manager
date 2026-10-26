#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$PROJECT_DIR/dist/M5 File Manager.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCHITECTURES="$(lipo -archs "$APP/Contents/MacOS/M5FileManager")"
if [[ "$ARCHITECTURES" == *arm64* && "$ARCHITECTURES" == *x86_64* ]]; then PACKAGE_ARCH=universal; else PACKAGE_ARCH="$ARCHITECTURES"; fi
ARCHIVE="$PROJECT_DIR/dist/M5-File-Manager-$VERSION-preview-$PACKAGE_ARCH.zip"
[[ ! -e "$ARCHIVE" ]] || { printf 'Archive already exists: %s\n' "$ARCHIVE" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
ditto --noextattr --norsrc -c -k --keepParent "$APP" "$ARCHIVE"
(cd "$PROJECT_DIR/dist" && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")
printf '%s\n' "$ARCHIVE"
