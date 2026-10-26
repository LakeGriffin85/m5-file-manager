#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/m5-terminal-tests.XXXXXX")"
trap 'rm -rf "$TEST_BUILD"' EXIT
cp "$PROJECT_DIR/Sources/Models.swift" "$TEST_BUILD/Models.swift"
cp "$PROJECT_DIR/Sources/TerminalTranscript.swift" "$TEST_BUILD/TerminalTranscript.swift"
cp "$PROJECT_DIR/Tests/TerminalTests.swift" "$TEST_BUILD/TerminalTests.swift"
export M5_FILE_MANAGER_LANGUAGE=de
cp "$PROJECT_DIR/Sources/Localization.swift" "$TEST_BUILD/Localization.swift"
cp "$PROJECT_DIR/Resources/Localizations.json" "$TEST_BUILD/Localizations.json"
swiftc "$TEST_BUILD/Localization.swift" -swift-version 5 -module-cache-path "$TEST_BUILD/module-cache" \
  "$TEST_BUILD/Models.swift" \
  "$TEST_BUILD/TerminalTranscript.swift" \
  "$TEST_BUILD/TerminalTests.swift" \
  -o "$TEST_BUILD/terminal-tests"
"$TEST_BUILD/terminal-tests"
