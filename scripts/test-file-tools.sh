#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/m5-tools-tests.XXXXXX")"
trap 'rm -rf "$TEST_BUILD"' EXIT
PYTHON_BIN="${PYTHON3:-$(command -v python3)}"
cp "$PROJECT_DIR/Sources/Models.swift" "$TEST_BUILD/Models.swift"
cp "$PROJECT_DIR/Sources/BoardSession.swift" "$TEST_BUILD/BoardSession.swift"
cp "$PROJECT_DIR/Tests/FileToolsTests.swift" "$TEST_BUILD/FileToolsTests.swift"
export M5_FILE_MANAGER_LANGUAGE=de
cp "$PROJECT_DIR/Sources/Localization.swift" "$TEST_BUILD/Localization.swift"
cp "$PROJECT_DIR/Resources/Localizations.json" "$TEST_BUILD/Localizations.json"
swiftc "$TEST_BUILD/Localization.swift" -swift-version 5 -module-cache-path "$TEST_BUILD/module-cache" \
  "$TEST_BUILD/Models.swift" "$TEST_BUILD/BoardSession.swift" \
  "$TEST_BUILD/FileToolsTests.swift" -o "$TEST_BUILD/file-tools-tests"
"$TEST_BUILD/file-tools-tests" "$PYTHON_BIN" "$PROJECT_DIR/Tests/mock_board.py"
