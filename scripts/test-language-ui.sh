#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/m5-language-ui-tests.XXXXXX")"
trap 'rm -rf "$TEST_BUILD"' EXIT
APP="$TEST_BUILD/Language UI Tests.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$TEST_BUILD/Sources"
cp "$PROJECT_DIR/Sources/"*.swift "$TEST_BUILD/Sources/"
rm "$TEST_BUILD/Sources/main.swift"
cp "$PROJECT_DIR/Resources/Localizations.json" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>language-ui-tests</string>
<key>CFBundleIdentifier</key><string>org.m5filemanager.desktop.language-ui-tests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1.0</string>
</dict></plist>
PLIST
unset M5_FILE_MANAGER_LANGUAGE
swiftc -swift-version 5 -module-cache-path "$TEST_BUILD/module-cache" \
  "$TEST_BUILD/Sources/"*.swift "$PROJECT_DIR/Tests/LanguageUITests.swift" \
  -o "$APP/Contents/MacOS/language-ui-tests" -framework AppKit -framework Foundation
"$APP/Contents/MacOS/language-ui-tests" --demo --demo-editor
