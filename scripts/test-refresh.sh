#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/m5-refresh-tests.XXXXXX")"
trap 'rm -rf "$TEST_BUILD"' EXIT
PYTHON_BIN="${PYTHON3:-$(command -v python3)}"
cp "$PROJECT_DIR/Sources/Models.swift" "$PROJECT_DIR/Sources/BoardSession.swift" \
   "$PROJECT_DIR/Sources/FileTreeRefresh.swift" "$PROJECT_DIR/Tests/RefreshTests.swift" "$TEST_BUILD/"
export M5_FILE_MANAGER_LANGUAGE=de
cp "$PROJECT_DIR/Sources/Localization.swift" "$TEST_BUILD/Localization.swift"
cp "$PROJECT_DIR/Resources/Localizations.json" "$TEST_BUILD/Localizations.json"
swiftc "$TEST_BUILD/Localization.swift" -swift-version 5 -module-cache-path "$TEST_BUILD/module-cache" \
    "$TEST_BUILD/Models.swift" "$TEST_BUILD/BoardSession.swift" \
    "$TEST_BUILD/FileTreeRefresh.swift" "$TEST_BUILD/RefreshTests.swift" \
    -o "$TEST_BUILD/refresh-tests"
"$TEST_BUILD/refresh-tests" "$PYTHON_BIN" "$PROJECT_DIR/Tests/mock_board.py"
