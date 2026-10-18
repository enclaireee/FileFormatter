# FileFormatter

A native, local-only batch file converter for macOS 26+ on Apple silicon.

**Status: 0.4.0 — feature complete for the private build.** The app converts images, PDFs, Office text, data, audio, and video; runs OCR into searchable PDFs; watches folders; finds duplicates; and exposes Finder Services and a menu bar extra. A signed DMG is produced by `make release`.

## What works now

- Drag-and-drop files or folders; `⌘O` file picker.
- Conversion planning in Rust (content detection, target naming, fidelity classification).
- Image conversion: JPEG, PNG, HEIC, AVIF, WebP, TIFF → JPEG, PNG, HEIC, AVIF, WebP, TIFF, and one-page PDF.
- Data conversion: CSV/TSV ↔ JSON ↔ YAML ↔ TOML ↔ XLSX.
- PDF page extraction to any image target, with one queue row per page.
- DOCX/PPTX extraction to Markdown, plain text, or HTML (text only).
- Audio: MP3, M4A/AAC, FLAC, WAV, AIFF, Opus, OGG Vorbis via FFmpeg, with metadata and chapters where the container supports them.
- Video: MP4, MOV, MKV (H.264 hardware), WebM (VP9/Opus); audio-track mapping and subtitle copying where supported.
- OCR: PDFs to searchable PDFs on-device with Vision; extracted text is embedded invisibly.
- Watch folders: drop a file into a watched folder and it converts with the chosen preset while the app runs.
- Duplicate finder: BLAKE3 content hashing, grouped results, keep-first cleanup to the Trash.
- Finder Services, open-with queueing, and a menu bar extra.
- Outcome-based sidebar presets across image, data, document, audio, and video families.
- Mixed-family queues: images, PDFs, data, and documents get independent targets in the same run.
- Fidelity badges (lossless / re-encode / lossy) and a pre-run plan summary.
- Same-folder output with a suffix, automatic collision numbering, atomic install.
- Run journal in Application Support and **Undo Run** from the completion sheet.
- History of recent runs.
- Debug-only end-to-end self-test (`--self-test`).

## Not yet

PDF merge/split/compression, Office images/styles, XLSX styling/formulas, App Intents/Shortcuts actions, Finder Sync, and notarization/sandboxing remain. The private build is unsandboxed and ad-hoc signed by design; see the decisions log.

## Requirements

- macOS 26 or 27, Apple silicon
- Xcode 27.1
- Rust 1.95 with the `aarch64-apple-darwin` target
- XcodeGen (`brew install xcodegen`)
- libwebp (`brew install webp`) — `bootstrap` vendors its static archive
- FFmpeg build dependencies (`brew install lame opus libvorbis libvpx dav1d`)
- `make bootstrap-media` builds the LGPL FFmpeg helpers; they are copied into the app bundle and signed ad-hoc
- ImageMagick only if you regenerate the app icon

## Build and run

```bash
make bootstrap   # build Rust, generate UniFFI bindings, create the Xcode project
make bootstrap-media  # build the LGPL FFmpeg helpers (first run only)
make build       # xcodebuild into .build/DerivedData
make run         # open the built app
make test        # Rust tests, Swift tests, app build, end-to-end self-test
make release     # Release build, ad-hoc signed .app, DMG and zip in dist/
```

The Rust archive and generated bindings are rebuilt by `bootstrap`; the archive is not committed. The Xcode project is generated from `project.yml`, so add new Swift files to `App/` and run `make project` or any `make` target.

## Release

`make release` produces:

- `dist/FileFormatter-0.4.0.dmg`
- `dist/FileFormatter-0.4.0.zip`
- `dist/checksums.txt`

The DMG is ad-hoc signed. On a friend's Mac, right-click → Open may be required the first time.

## Architecture

```
SwiftUI app
  └─ FileFormatterCore (Swift package)
       ├─ ConversionService, ImageConverter, RunJournal
       └─ FileFormatterRust (Swift package)
            ├─ C module for the UniFFI headers
            └─ libfileformatter_core.a (Rust: detection + planning)
```

- **Swift** owns UI, ImageIO conversion, WebP (through a C shim), PDF writing, Vision OCR, watch folders, duplicate UI, file access, and journal writes.
- **Rust** owns deterministic planning and data conversion: content detection, output naming, fidelity, CSV/JSON/YAML/TOML/XLSX, Office text extraction, and BLAKE3 duplicate hashing. The FFI is synchronous UniFFI.
- **FFmpeg** (LGPL-2.1, bundled) handles audio/video codecs and containers; helpers are copied into `Contents/Resources/Helpers` and signed.
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

## Data conversion rules

- Input must be UTF-8; a BOM is tolerated.
- CSV/TSV are read as a table with a header row. Values are treated as strings so IDs and ZIP codes keep their leading zeros.
- JSON ↔ CSV requires a top-level array of objects. Nested values are written as compact JSON.
- YAML and TOML preserve data, not comments or anchors; formatting always changes, so these conversions are labeled re-encode in the queue.

## Presets

The sidebar ships with outcome-based presets: Web Images, Archive Photos, Images → PDF, PDF → PNG Pages, Lossless PNG, Data → JSON, Data → XLSX, Office → Markdown, Audio for iPhone, Lossless Audio, Video H.264, and WebM VP9. A preset sets the per-family targets, quality, and suffix; changing them manually clears the checkmark.

## PDF, Office, and media limits

- PDF pages are rendered at 2× page size, one output file per page, or OCR'd into one searchable PDF. PDF merge/split and true image-level compression are not implemented.
- DOCX/PPTX extraction preserves paragraph and slide text only; styles, tables beyond their text, images, charts, and layout are not preserved.
- XLSX reading uses the first worksheet. XLSX writing supports arrays of objects; formulas and styling are not authored.
- Video re-encodes rather than remuxing; H.264 hardware encode and VP9/Opus WebM are supported. Subtitle tracks are copied where the container allows.
- OGG Vorbis output depends on the bundled FFmpeg build (it includes libvorbis).

## Privacy

No network entitlement, no telemetry, no uploads. Everything is processed locally. Generated files are the only writes; replaced files are never silently destroyed. **Undo Run** moves generated files to the Trash.

## License

Private project. Third-party license notices will be added with the bundled FFmpeg work; the Rust dependencies are permissively licensed (UniFFI MPL-2.0, thiserror MIT/Apache-2.0).
