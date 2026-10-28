# Publication status

The public source is available at [LakeGriffin85/m5-file-manager](https://github.com/LakeGriffin85/m5-file-manager), first published on 2026-10-28. The [v1.1.0 preview release](https://github.com/LakeGriffin85/m5-file-manager/releases/tag/v1.1.0-preview.1) provides the universal macOS app ZIP, its SHA-256 checksum and the MIT license. The build is ad-hoc signed and is not Apple-notarized.

## Published source boundary

- Standalone allowlisted source tree and fresh Git history; no upstream private history or remotes.
- Neutral app identity, generated icon, English/German interface and MIT license.
- Synthetic test fixtures and generic documentation.
- Preview app build and reproducible ZIP/checksum packaging.
- Static checks for unexpected publication files and common credentials or machine-specific paths.

## Before later releases

1. Review the source, history and selected artifacts for the intended public release. Keep local logs, backups and private repository content outside this source tree.
2. Run `python3 scripts/check-public.py`, the regression suites and demo UI tests. Review archive contents and source history as well as the current files.
3. Test the preview on the intended hardware, target macOS versions and both CPU architectures.
4. Choose source-only preview distribution or prepare a signed binary release. The default local signature is ad hoc. Developer ID distribution requires an appropriate certificate, hardened runtime, notarization and validation of the downloaded artifact on a clean Mac. No signing identity or credentials are included here.
5. Publish only the sanitized repository and explicitly selected release artifacts. Never add personal logs, board backups, old app bundles or signing keys.

The repository license covers this project's code and generated resources. Third-party product names identify compatibility. Native macOS dialogs may follow the system language, and device-generated exceptions/output remain original.

## Download verification

On 2026-10-28 the app ZIP and checksum were downloaded from the public release without authentication. Both matched the reviewed local artifacts; ZIP integrity and archive-entry checks passed. This verifies the published bytes, not Gatekeeper acceptance or physical-device compatibility.
