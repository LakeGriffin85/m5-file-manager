#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/m5-delete-preferences.XXXXXX")"
trap 'rm -rf "$TEST_BUILD"' EXIT
cp "$PROJECT_DIR/Sources/Models.swift" "$PROJECT_DIR/Sources/DeletionBackupPreferences.swift" \
   "$PROJECT_DIR/Tests/DeletionBackupTests.swift" "$TEST_BUILD/"
export M5_FILE_MANAGER_LANGUAGE=de
cp "$PROJECT_DIR/Sources/Localization.swift" "$TEST_BUILD/Localization.swift"
cp "$PROJECT_DIR/Resources/Localizations.json" "$TEST_BUILD/Localizations.json"
swiftc "$TEST_BUILD/Localization.swift" -swift-version 5 -module-cache-path "$TEST_BUILD/module-cache" \
    "$TEST_BUILD/Models.swift" "$TEST_BUILD/DeletionBackupPreferences.swift" \
    "$TEST_BUILD/DeletionBackupTests.swift" -o "$TEST_BUILD/preferences-tests"
"$TEST_BUILD/preferences-tests"
