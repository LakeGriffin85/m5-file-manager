# Tests

Run from the repository root on macOS with Swift and Python 3 installed:

```sh
./scripts/test.sh
./scripts/test-file-tools.sh
./scripts/test-service.sh
./scripts/test-refresh.sh
./scripts/test-sd.sh
./scripts/test-move.sh
./scripts/test-deletion-backup.sh
./scripts/test-terminal.sh
./scripts/test-sync.sh
./scripts/test-localization.sh
```

Most suites build temporary Swift executables and use `mock_board.py` through a local pseudo-terminal. They never enumerate or open physical USB devices. Test fixtures, program text and binary payloads are synthetic. Backend tests force German for deterministic legacy assertions. Localization tests use in-memory preferences and cover both languages.

The filesystem compatibility suite additionally creates and removes its own uniquely named temporary directory beneath the **existing directory you provide**:

```sh
./scripts/test-nas-backup.sh /tmp
```

To test an actual mounted network filesystem, provide a writable folder on that filesystem instead. A local `/tmp` run tests the forced fallback and local filesystem behavior, not NAS compatibility.

Native language UI tests require an interactive macOS window session:

```sh
./scripts/test-language-ui.sh
```

They launch a temporary demo app with its own bundle identifier, exercise the actual language-menu action, and verify that unsaved editor text and CSV cells are preserved. No device access occurs. An optional `M5_UI_ARTIFACTS` directory receives rendered views for visual inspection.

The local tests do not establish hardware compatibility, Intel runtime coverage when run on Apple Silicon, or minimum-supported-macOS runtime behavior.
