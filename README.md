# FileFormatter

A native, local-only batch file converter for macOS 26+ on Apple silicon.

**Status: M0 foundation complete.** The app builds, plans conversions in Rust, converts images with ImageIO, writes outputs atomically, journals every run, and can undo the run by moving generated files to the Trash.

## What works now

- Drag-and-drop files or folders; `⌘O` file picker.
- Conversion planning in Rust (content detection, target naming, fidelity classification).
- Image conversion: JPEG, PNG, HEIC, AVIF, TIFF → JPEG, PNG, HEIC, AVIF, TIFF.
- Fidelity badges (lossless / re-encode / lossy) and a pre-run plan summary.
- Same-folder output with a suffix, automatic collision numbering, atomic install.
- Run journal in Application Support and **Undo Run** from the completion sheet.
- History of recent runs.
- Debug-only end-to-end self-test (`--self-test`).

## Not yet

WebP, PDF operations, audio, video, CSV/JSON/Office, OCR, presets, watch folders, duplicate finder, Finder quick actions, DMG packaging. These are scheduled in [`PRODUCTION-PLAN.md`](PRODUCTION-PLAN.md).

## Requirements

- macOS 26 or 27, Apple silicon
- Xcode 27.1
- Rust 1.95 with the `aarch64-apple-darwin` target
- XcodeGen (`brew install xcodegen`)
- ImageMagick only if you regenerate the app icon

## Build and run

```bash
make bootstrap   # build Rust, generate UniFFI bindings, create the Xcode project
make build       # xcodebuild into .build/DerivedData
make run         # open the built app
make test        # Rust tests, Swift tests, app build, end-to-end self-test
make release     # Release build and a zip in dist/
```

The Rust archive and generated bindings are rebuilt by `bootstrap`; the archive is not committed. The Xcode project is generated from `project.yml`, so add new Swift files to `App/` and run `make project` or any `make` target.

## Architecture

```
SwiftUI app
  └─ FileFormatterCore (Swift package)
       ├─ ConversionService, ImageConverter, RunJournal
       └─ FileFormatterRust (Swift package)
            ├─ C module for the UniFFI headers
            └─ libfileformatter_core.a (Rust: detection + planning)
```

- **Swift** owns UI, ImageIO conversion, file access, and journal writes.
- **Rust** owns deterministic planning: content detection, output naming, fidelity. The FFI is synchronous UniFFI; long work is chunked later.
- **Static link**, no embedded Rust dylib, no signing surface beyond the app itself.
- The private build is **unsandboxed** for now; see [`docs/DECISIONS.md`](docs/DECISIONS.md).

## Repository layout

```
App/                         SwiftUI app target
Config/                      Info.plist, future sandbox entitlements
Packages/FileFormatterCore/  Domain, conversion, journal, tests
Packages/FileFormatterRust/  UniFFI-generated Swift + C module + static archive
rust/                        Rust workspace
scripts/                     bootstrap, build, test, self-test
Tests/                       Fixture space for the next milestones
docs/                        Decisions and supporting notes
project.yml                  XcodeGen project definition
```

## Privacy

No network entitlement, no telemetry, no uploads. Everything is processed locally. Generated files are the only writes; replaced files are never silently destroyed. **Undo Run** moves generated files to the Trash.

## License

Private project. Third-party license notices will be added with the bundled FFmpeg work; the Rust dependencies are permissively licensed (UniFFI MPL-2.0, thiserror MIT/Apache-2.0).
