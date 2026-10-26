#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/m5-localization-tests.XXXXXX")"
trap 'rm -rf "$TEST_BUILD"' EXIT
cp "$PROJECT_DIR/Resources/Localizations.json" "$TEST_BUILD/"
unset M5_FILE_MANAGER_LANGUAGE
swiftc -swift-version 5 -module-cache-path "$TEST_BUILD/module-cache" \
  "$PROJECT_DIR/Sources/Localization.swift" "$PROJECT_DIR/Sources/Models.swift" \
  "$PROJECT_DIR/Tests/LocalizationTests.swift" -o "$TEST_BUILD/localization-tests"
"$TEST_BUILD/localization-tests"
