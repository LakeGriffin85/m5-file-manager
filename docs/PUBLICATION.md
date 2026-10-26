# Publication status

This is a locally prepared public preview. No GitHub repository, upload or release is implied by the files in this directory.

## Prepared

- Standalone allowlisted source tree and fresh local Git history; no upstream private history or remotes.
- Neutral app identity, generated icon, English/German interface and MIT license.
- Synthetic test fixtures and generic documentation.
- Preview app build and reproducible ZIP/checksum packaging.
- Static checks for unexpected publication files and common credentials or machine-specific paths.

## Before publishing

1. Review the source and artifacts, choose the GitHub owner and repository name, and approve that specific publication.
2. Run `python3 scripts/check-public.py`, the regression suites and demo UI tests. Review archive contents and source history as well as the current files.
3. Test the preview on the intended hardware, target macOS versions and both CPU architectures.
4. Choose source-only preview distribution or prepare a signed binary release. The default local signature is ad hoc. Developer ID distribution requires an appropriate certificate, hardened runtime, notarization and validation of the downloaded artifact on a clean Mac. No signing identity or credentials are included here.
5. Publish only the sanitized repository and explicitly selected release artifacts. Never add personal logs, board backups, old app bundles or signing keys.

The repository license covers this project's code and generated resources. Third-party product names identify compatibility. Native macOS dialogs may follow the system language, and device-generated exceptions/output remain original.
