# Local public-preview validation

Date: 2026-10-26. Host: Apple Silicon, macOS 27.0.1, Apple Swift 6.4; production build targets macOS 14 with Swift language mode 5.

| Suite | Passed checks | Scope |
| --- | ---: | --- |
| Transport integration | 147 | Pseudo-terminal device |
| File tools | 84 | Pseudo-terminal device |
| Device service | 53 | Pseudo-terminal device |
| SD profiles | 212 | Simulated firmware/drivers |
| Move/deletion | 112 | Pseudo-terminal device |
| File-tree refresh | 22 | Pseudo-terminal device |
| Terminal | 41 | Pure transcript tests |
| Sync / preview / live sync | 32 | Pseudo-terminal device and local watcher |
| Filesystem fallback | 25 | Forced fallback and local `/tmp`, not a network volume |
| Deletion preferences | 17 | In-memory preferences |
| Localization | 1430 | Catalog, placeholders, language persistence and errors |
| Native language UI | 17 | Demo app, actual language menu, no device |
| Publication scanner controls | 13 | Synthetic positive/negative inputs |
| **Total** | **2205** | **Local validation only** |

The native UI test exercises German → English → German while preserving unsaved editor text, CSV cells and open windows. App controls, preview titles, terminal placeholder and SD labels update. Generated demo views were visually inspected in both languages. No real board or active user app was connected, restarted or modified.

The universal production executable contains arm64 and x86_64 slices. Native build, strict code-signature verification, ZIP contents and checksum generation passed. Source files, app resources, executable strings and the ZIP were checked for machine-specific identifiers, personal artwork and accidental private files. No static findings remained. Only synthetic examples and freshly generated demo images are included.

The app is ad-hoc signed, not Developer ID-signed or Apple-notarized. Intel execution, macOS 14 execution and real-board use of this public edition have not been tested. AppKit demo launching requires an interactive macOS session; it cannot be validated inside a shell-only sandbox.

This report records local checks, not a GitHub publication or blanket hardware compatibility claim. Review current sources and artifacts again when preparing a later release.
