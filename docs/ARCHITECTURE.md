# Architecture and invariants

The app uses AppKit and Foundation. It has no runtime package manager or external service dependency.

- `BoardSession.swift` exclusively owns the serial descriptor and implements paced classic MicroPython raw REPL. Each remote command uses isolated globals. File operations interrupt Python; terminal/file writes never run concurrently.
- `DeviceService.swift` serializes operations, tracks session identity, rejects stale editor/export sessions and delivers UI updates on the main queue.
- `AppController.swift` owns the file browser, Finder operations, dialogs and explicitly enabled live-sync watcher. Restart clears stale file state. Language changes enqueue no device operations.
- `DocumentWindow.swift` preserves unsaved text across device-state changes. It compares the exact known revision before replacing files and keeps a local original.
- `PreviewWindow.swift` displays CSV/JSON/images without changing the source. `Models.swift` bounds parser and live-sync inputs.
- `Localization.swift` resolves a bilingual catalog and inserts dynamic values in a single pass. Values are opaque, so a path containing `{1}` is not interpreted as another placeholder. `LocalizationUI.swift` updates app labels while excluding table rows and text-view content. Historical terminal output stays original.

## File safety

Uploads write to a unique staging file, check each received CRC and readback, and verify the final size. When replacing a target, rename/rollback logic preserves the old file until installation is attempted. A lost acknowledgement remains uncertain, never assumed successful or undone. Power loss during final filesystem renames is not guaranteed atomic.

Downloads stage locally before final installation. On filesystems without exclusive rename, an exclusive copy is read back and checked before the staging source is removed. Existing targets are never silently replaced.

Moving within a storage volume uses whole-batch preflight and acknowledged individual renames. Moving across volumes is rejected in favor of copying. Deletion with backup proceeds only after a verified local copy. Root paths and ambiguous mount states are protected.

Bounded preview reads check regular-file type and size before and after reading, enforce exact decoded block lengths and reject short reads. Same-size concurrent file edits cannot be detected by these checks alone.

Live sync requires explicit folders, snapshots stable across two samples, known-baseline conflict checks, original backups and readback before restart. It never propagates local deletions and never starts automatically when the app opens.

## Validation scope

The pseudo-terminal simulator executes command bodies against a temporary filesystem and injects faults, lost responses and disconnects. It covers protocol and recovery logic, not physical USB drivers, GPIO wiring, filesystem durability or firmware-specific timing. Native UI tests use demo data and a separate settings domain; they never connect to a board.
