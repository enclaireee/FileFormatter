# Decision log

## D-001 — Target macOS 26+, Apple silicon

All target Macs run macOS 26/27. Deployment is macOS 26.0, built with Xcode 27.1 and the macOS 27 SDK. No legacy design or API fallbacks. This matches the user's confirmed environment.

## D-002 — Rust is a linked static archive behind a C module

The Rust core is a `staticlib`, linked into the app through a tiny SwiftPM C target (`fileformatter_coreFFI`) plus generated UniFFI Swift. A static XCFramework consumed by a SwiftPM `binaryTarget` was built first, but SwiftPM did not expose the archive's Clang module (the generated Swift could not import the FFI module). The C-target + archive approach builds and links reliably and remains a static link with no embedded dylib.

Consequences: `bootstrap` copies the archive into `Packages/FileFormatterRust/Vendor/`; the archive is gitignored. The XCFramework remains useful for a future prebuilt distribution artifact.

## D-003 — UniFFI synchronous API only

UniFFI 0.32's async Swift support is not `Sendable`-clean and has no cancellation; the synchronous API is mature and maps errors to `throws`. Planning/detection calls are short. Hashing and duplicate scans will be chunked per file so Swift can cancel between calls. Panics are caught at the FFI boundary and returned as `UnexpectedError`.

## D-004 — Unsandboxed private build (temporary)

The app is currently **not sandboxed**.

Reason: the product defaults to writing converted files next to the originals. A sandbox grant obtained from an open panel or a drag is scoped to the selected file, not its parent directory, so creating a sibling output fails. Sandboxing therefore needs either a chosen output folder or a directory-grant flow.

Decision: ship the private build unsandboxed while the core loop is validated. Revisit before broader distribution or if the app is submitted to the App Store. `Config/FileFormatter.entitlements` is retained for that work. Consequence: no `com.apple.security.*` entitlements, and `Hardened Runtime` is disabled by Xcode for ad-hoc signing.

## D-005 — Ad-hoc signing, no notarization

There is no Developer ID in this setup. The app is signed ad-hoc ("Sign to Run Locally"). Friends may need right-click → Open. A Developer ID/notarization pipeline is a later, isolated change; the project already builds an archiveable `.app`.

## D-006 — WebP requires libwebp

Verified on this machine: ImageIO reads WebP but cannot write it; `sips` has no WebP output; the Homebrew FFmpeg build also lacks a WebP encoder. WebP output will use bundled libwebp (BSD-3) in M1. HEIC, AVIF, JPEG, PNG, TIFF, and GIF encode natively.

## D-007 — XcodeGen for a reproducible project

The `.xcodeproj` is generated from `project.yml`. Apple's Xcode build system remains the build tool; XcodeGen only removes hand-maintained project-file churn. The generated project is committed. New files under `App/` require regeneration.

## D-008 — First slice intentionally image-only

M0 proves the spine with images. WebP, PDF, data/Office, audio, video, OCR, watch folders, and duplicates are milestone work. This keeps the first build honest and testable rather than shipping a broad but shallow converter.

## D-009 — Debug self-test

`--self-test` is compiled only in DEBUG. It creates a PNG, plans it through Rust, converts to JPEG through ImageIO, writes and reads the journal, undoes the run, and exits with status 0. This is the CI smoke test until UI tests land.


## D-010 — WebP is encoded through a C shim over vendored libwebp

ImageIO reads WebP but cannot write it on macOS 27, and the Homebrew FFmpeg build has no WebP encoder. WebP output therefore uses libwebp 1.6.0 (BSD-3), vendored as `libwebp.a` + `libsharpyuv.a` and called through a small C shim (`CWebP`). The shim accepts straight RGBA, allows explicit quality, and is covered by the all-targets image test.

The archives come from Homebrew in `bootstrap`; a pinned source build is the next reproducibility step. Headers and the license are committed; the `.a` files are gitignored.

## D-011 — Data conversion is UTF-8, header-row, string-preserving

CSV/TSV ↔ JSON ↔ YAML ↔ TOML is implemented in Rust. Values read from a table are kept as strings so identifiers like `00501` do not become integers. JSON → CSV requires an array of objects. YAML comments/anchors and TOML comments are not preserved; those conversions are labeled re-encode.

XLSX and Office extraction are not part of this slice.

## D-012 — Images → PDF is one page per image

The PDF target assembles a single-page PDF at the image's pixel dimensions, using Core Graphics. It does not combine multiple images into one PDF yet. PDF input/page extraction is deferred to the next M1 slice, because it needs a multi-output queue item.

## D-013 — Rust staticlib builds without LTO

The archive initially used `lto = "thin"`. Rust 1.95 emits LLVM 22 bitcode that Apple's linker could not resolve for the newly added `convert_data` entry point, even though the dylib contained it. Setting `lto = false` produced object code the linker resolves reliably. Revisit ThinLTO with a matching toolchain or a prebuilt archive later; the performance impact is small for the planning layer.


## D-014 — PDF pages are first-class queue items

A PDF expands into one `ConversionItem` per page at plan time, each with `pageIndex`/`pageCount` and its own output name. The renderer uses PDFKit's `PDFPage.thumbnail` at 2× page bounds and feeds the resulting `CGImage` through the same encoder used by images. This gives progress, undo, and fidelity per page. A multi-page PDF therefore reports `extract` fidelity per page, and the run summary lists every output.

## D-015 — Office extraction is text-only and native

DOCX/PPTX are unpacked with `zip` and parsed with `quick-xml`; DOCX takes `word/document.xml`, PPTX walks slide XML. Targets are Markdown, plain text, and HTML. Styles, images, charts, shapes, and layout are not preserved, and the UI says so. XLSX uses `calamine`, first worksheet only. This avoids a 700 MB LibreOffice dependency and is honest about fidelity.

## D-016 — XLSX output uses rust_xlsxwriter

CSV/JSON arrays of objects can be written to XLSX with `rust_xlsxwriter`. Binary XLSX input must not be read as UTF-8; the conversion path branches on the source extension before text decoding. Round-trip tests cover CSV → XLSX → CSV.

## D-017 — Presets are outcome-based, applied in the sidebar

Presets set the per-family targets, quality, and suffix rather than encoding codec details. The sidebar shows a checkmark when the current recipe matches. Presets do not bypass preview: applying one replans the queue.


## D-018 — LGPL FFmpeg helper and media backend

FFmpeg 8.0.1 is built with `--disable-gpl --disable-nonfree --disable-version3`, VideoToolbox/AudioToolbox, libmp3lame, libopus, libvorbis, libvpx, and libdav1d. The static binaries live in `vendor/ffmpeg/bin`, are copied into `Contents/Resources/Helpers`, and are ad-hoc signed. `MediaConverter` drives ffmpeg with argument arrays, a scrubbed PATH, progress parsing, cancellation, and a stderr tail. GPL encoders (x264/x265) are never used; H.264/HEVC encoding goes through VideoToolbox.

## D-019 — OCR is local and embedded invisibly

Vision performs on-device text recognition. Searchable PDFs redraw the original page (vector or image) and add an invisible Core Text layer at Vision's bounding boxes. This preserves the page's appearance while making the text selectable. OCR is triggered by the PDF OCR toggle, not for every PDF by default.

## D-020 — Watch folders are foreground-only

A `DispatchSource` monitors each watched folder while FileFormatter runs. Events debounce for ~0.9 s, files must be size/mtime-stable, and processed keys prevent duplicate runs. Rules persist in Application Support and can be paused per folder. No background agent or login item is installed in 0.4.0.

## D-021 — Duplicate detection uses BLAKE3

The Rust core hashes files in 1 MB buffered chunks with BLAKE3, filters empty files, groups by hash, and sorts by reclaimable bytes. The UI keeps the first path in a group and moves the rest to the Trash. Hashing is chunked but not yet cancellable mid-file.

## D-022 — Release is ad-hoc signed and unsandboxed

`make release` builds arm64-only, bundles and re-signs helpers, creates a DMG and zip, and writes checksums. No Developer ID exists, so Gatekeeper requires right-click → Open on another Mac. Sandboxing is deferred (D-004); notarization is a one-command change once a Developer ID exists.

## D-023 — Background removal uses Apple Vision

`VNGenerateForegroundInstanceMaskRequest` lifts every detected subject and keeps alpha. It is on-device, fast on Apple silicon, and needs no bundled model. Images with no clear subject fail per file with a message instead of producing an empty cutout. A bundled segmentation model was rejected for size and licensing.

## D-024 — Finder actions are Services, not a Finder Sync extension

Each quick action is an `NSServices` entry with `NSUserData` set to a `QuickAction` id, dispatched by one `quickAction:userData:error:` selector into `AppModel.quickRun`. Services need no extension target, sandbox, or entitlements; Finder Sync would add a top-level menu but requires both. Services can be toggled in Keyboard → Services settings.

## D-025 — Office conversion uses a small block model; PDF compress uses the Quartz filter

DOCX/PPTX parse into `Heading`/`Paragraph(runs)`/`ListItem`/`Table`/`Image` blocks, then render to Markdown, HTML, or text. Images are copied to `<stem>_files/` next to the output with sanitized names, and Swift adds that folder to the run outputs so Undo removes it. This supersedes D-015's text-only scope. PDF compression applies `/System/Library/Filters/Reduce File Size.qfilter` through `QuartzFilter`, because PDFKit's write options did not reduce size in testing.
