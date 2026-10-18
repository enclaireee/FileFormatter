# FileFormatter — Production Plan

**Status:** Draft for approval  
**Date:** 18 October 2026  
**Target:** macOS 26+, Apple silicon, private use / small-circle distribution  
**Companion:** `FileFormatter-Product-UX-Spec.md` (original product/UX intent)

---

## Implementation status

**M0 — Foundation: complete (18 Oct 2026).** The app builds and runs on macOS 27. The debug self-test plans a PNG in Rust, converts it to JPEG through ImageIO, persists the run journal, and undoes the run, all inside the signed app bundle. The UI shell, queue, inspector, fidelity badges, completion sheet, and history are in place.

**M1 — In progress (18 Oct 2026).** Shipped: WebP encoding via vendored libwebp; mixed image/data queues with independent targets; CSV/TSV ↔ JSON ↔ YAML ↔ TOML; image → one-page PDF. The in-app self-test now covers a mixed WebP + CSV→JSON run, journal, and undo. Remaining: PDF page extraction, Office extraction, presets, and polish.

Deliberate M0 deviation: the private build is **unsandboxed**; see D-004 in `docs/DECISIONS.md`. The Rust bridge links a static archive through a C module rather than a SwiftPM `binaryTarget`; see D-002.

**Next:** finish M1 — PDF page extraction, Office extraction, presets, and UI polish.

## 0. Decisions locked

| Area | Decision |
|---|---|
| Distribution | Private use, optionally shared with a few friends. Ad-hoc signing, no App Store, no notarization; unsandboxed private build for M0 (see D-004) |
| Hardware | Apple silicon only (arm64) |
| Engine | Rust core + native Apple codecs + bundled LGPL FFmpeg for gaps |
| Families | Images, audio, video, PDF & documents, data (CSV/JSON/YAML/TOML/XLSX) |
| Office | Native limited: DOCX/PPTX text + images extraction, XLSX ↔ CSV/JSON. No faithful Office → PDF |
| Features | OCR/searchable PDF, Finder + menu-bar quick actions, watch folders, duplicate finder |
| Data-loss policy | No silent loss. Every conversion declares a fidelity level and shows what is preserved or dropped |
| Minimum OS | macOS 26+ (all target Macs run 26/27; Liquid Glass and current SwiftUI APIs are available unconditionally) |
| UI | Native macOS, modern, production polish; the queue is the workspace |

---

## 1. What "production ready" means here

This is not a demo that converts one file. Done means:

- **No silent data loss.** Every job is planned, classified, and reported. Destructive conversions are explicit.
- **Atomic and reversible.** Temp-file writes, journaled runs, 30-day undo for new outputs and replaced originals.
- **Fast under real batches.** 1,000-file queues, 4K video, long audio, and 500-page PDFs remain responsive.
- **Robust against bad input.** Corrupt, truncated, mislabeled, and hostile files fail one item, not the app.
- **Native quality.** Swift 6 concurrency, no main-thread I/O, standard macOS interaction, dark mode, VoiceOver, keyboard-first.
- **Reproducible builds.** One bootstrap command produces a signed `.app` and a DMG; tests and benchmarks run from the command line.
- **Diagnosable.** Structured logs, exportable diagnostics, no telemetry, no network access.
- **Documented.** README, format matrix, fidelity rules, build/release instructions, third-party licenses.

---

## 2. Product definition

FileFormatter is a native batch converter for people who want one tool for every file family, without uploading anything and without wondering what was silently lost.

It differs from a classic converter in three ways:

1. **Capability-driven.** The UI only offers conversions the engine can actually perform, with a predicted fidelity level for each file.
2. **Mixed batches are first-class.** Images, video, audio, PDFs, and data files can share one queue; each family gets its own target settings.
3. **Verifiable.** A pre-run fidelity plan and a post-run report state exactly what was preserved, re-encoded, or dropped.

### 2.1 Boundaries, stated honestly

"Anything to anything" is a direction, not a literal promise. These are deliberately unsupported in v1:

- PDF → DOCX, Office → PDF, and faithful Office rendering (no layout engine).
- Editing content: cuts, crops beyond resize, filters, retouching.
- Cloud conversion, accounts, upload, sync.
- Arbitrary scripting/plugins.
- Bit-exact conversion between lossy codecs (impossible by definition); we expose the loss instead of hiding it.
- HDR/Dolby Vision authoring or tone mapping beyond preserving the source's metadata.

---

## 3. Format matrix — v1

The matrix below is the contract the capability registry will encode. Inputs are detected by content, not extension.

| Family | Read | Write | Notes / gaps |
|---|---|---|---|
| **Images** | JPEG, PNG, HEIC/HEIF, AVIF, WebP, TIFF, GIF, BMP, ICO, PSD, RAW (CR2/CR3/NEF/ARW/DNG/RAF/ORF/RW2), SVG, PDF page | JPEG, PNG, HEIC, AVIF, WebP, TIFF, GIF, BMP, ICO, PDF | Animated GIF/WebP preserved where possible; RAW via ImageIO; SVG rasterized via resvg; WebP via bundled libwebp (ImageIO cannot write it here); alpha, profiles, EXIF/IPTC/XMP |
| **Audio** | MP3, AAC/M4A, ALAC, FLAC, WAV, AIFF, OGG Vorbis, Opus, WMA, AC3/EAC3, CAF | MP3, AAC/M4A, ALAC, FLAC, WAV, AIFF, OGG Vorbis, Opus | AudioToolbox covers MP3/AAC/ALAC/FLAC/Opus/WAV/AIFF natively; MP3 is royalty-free; FFmpeg handles Vorbis/WMA/AC3 and awkward containers. Bitrate/sample-rate/channel control; metadata, album art, chapters |
| **Video** | MP4, MOV, M4V, MKV, WebM, AVI, FLV, TS/MTS, MPEG, WMV, 3GP | MP4, MOV, MKV, WebM, GIF (short), image sequence | H.264/HEVC/ProRes/VP9/AV1 decode; H.264/HEVC hardware encode; AV1/VP9 software encode; remux without re-encoding. HEVC must be tagged `hvc1`, not `hev1`, for AVFoundation compatibility |
| **PDF** | PDF (unlocked), images, text/Markdown/HTML | PDF, PNG/JPEG/TIFF pages, searchable PDF | Merge, split, extract pages/images/text, rotate, images → PDF, OCR; compression is rasterizing-only and clearly labeled |
| **Office** | DOCX, PPTX, XLSX | TXT/MD/HTML (DOCX/PPTX), CSV/JSON (XLSX), XLSX (from CSV/JSON) | Text, headings, lists, tables, embedded images; styles/shapes/charts/animations are reported as dropped |
| **Data** | CSV, TSV, JSON, YAML, TOML, XLSX, XML | CSV, TSV, JSON, YAML, TOML, XLSX | Delimiter, headers, encoding, type inference, nested JSON flatten; YAML comments/anchors and XLSX formulas are lossy |

### 3.1 Cross-family conversions

| From | To | Kind |
|---|---|---|
| Video | Audio (MP3/AAC/FLAC/WAV) | Extraction |
| Video | GIF, image sequence, single frame | Extraction |
| Audio | Video container with cover art | Later (v1.1) |
| PDF | Images, text, searchable PDF | Extraction / OCR |
| Images | PDF, multi-page PDF | Assembly |
| Markdown/HTML | PDF | Rendering |
| Data ↔ data, Office → text/data | | Transformation |

---

## 4. Fidelity contract

Every planned job gets one level. The level is visible in the queue and summarized before running.

| Level | Label | Meaning | Example |
|---|---|---|---|
| **L0** | Lossless | Streams copied bit-for-bit or remuxed; no generation loss, when the target container accepts the codecs | MKV → MP4 remux, FLAC → ALAC |
| **L1** | Lossless re-encode | Lossless codecs or uncompressed representations; pixels/samples unchanged | PNG → TIFF, WAV → AIFF |
| **L2** | Re-encode | Lossy codec to lossy codec at a chosen quality; some generation loss | H.264 → HEVC, JPEG → WebP |
| **L3** | Lossy / destructive | Drops tracks, metadata, pages, animation, HDR, or alpha | Video → GIF, HDR → SDR, DOCX → Markdown |
| **L4** | Extraction | Produces a new artifact from part of the input; the rest is intentionally not represented | Video → MP3, PDF → PNG |

Rules:

- **L0/L1 are the default whenever possible.** The target picker marks lossless targets.
- **L3/L4 require an explicit acknowledgement** on the first run of that recipe; the confirmation names what is lost (tracks, metadata, resolution, pages). It is never buried in an advanced pane.
- **Metadata is preserved by default** when the target container supports it. Stripping is a choice, not a surprise.
- **Multi-track media:** remux preserves every track, chapter, and subtitle by default; re-encode offers "preserve all audio tracks" or a selection.
- **Fidelity report:** after each run, a report lists input/output streams, codec/container changes, metadata diff, dropped items, sizes, and hashes for L0/L1. Exportable as JSON/Markdown.
- **No hidden download/upload.** OCR language data is local; no network entitlement.

---

## 5. User experience

### 5.1 Main window

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ ◀ ▶  FileFormatter                                  [＋ Add]   [▶ Convert 12] │
├──────────────────┬──────────────────────────────────────────┬────────────────┤
│ CONVERT          │ 12 files · 2.8 GB → ≈740 MB · 3 lossless │ TARGET         │
│  Presets         │                                          │                │
│  Recent          │  File                →  Target   Fidelity│ Images: WebP ▾ │
│ WATCH FOLDERS    │  IMG_4821.HEIC      →  WebP     Re-encode│ Quality 80     │
│ DUPLICATES       │  clip.mkv           →  MP4      Lossless │ Resize 2400    │
│ HISTORY          │  score.mp3          →  FLAC     Lossless │ Metadata keep  │
│                  │  contract.pdf       →  PDF      Re-encode│                │
│                  │  data.csv           →  JSON     Lossless │ Video: MP4 ▾   │
│                  │                                          │ Audio: FLAC ▾  │
│                  │ ⚠ 1 file needs attention                 │ PDF: OCR off   │
├──────────────────┴──────────────────────────────────────────┴────────────────┤
│ Keep originals · Same folder, “-converted” suffix        Save as Preset…  ⌘S │
└──────────────────────────────────────────────────────────────────────────────┘
```

- **Sidebar:** Convert, Watch Folders, Duplicates, History; presets and recent runs nested under Convert.
- **Queue:** source, target, fidelity badge, status; sortable and filterable; per-file target override and skip.
- **Inspector:** target settings grouped by family (Images, Video, Audio, PDF, Data). Mixed batches show one card per family.
- **Fidelity strip:** a live summary ("3 lossless · 8 re-encode · 1 extraction") that opens the detailed plan.
- **Run:** shows the count of runnable files; blocking issues focus in place, never a modal wall.
- **Bottom bar:** destination mode, suffix, **Save as Preset**.

### 5.2 Supporting surfaces

- **Watch Folders:** folder → preset → destination; debounce and stability checks; pause/resume; recent activity; notifications; launch-at-login optional.
- **Duplicates:** size prefilter, BLAKE3 grouping, preview, keep-one workflow, move extras to Trash with undo.
- **History:** every run with recipe snapshot, fidelity report, and Undo Run.
- **Menu bar:** drop target, current progress, recent runs, pause.
- **Quick actions:** Services menu, Shortcuts/App Intents, drag onto the Dock icon.
- **Settings:** defaults per family, destination, recovery, OCR languages, watch folders, diagnostics.
- **Onboarding:** empty state teaches drop → pick target → preview → convert; optional sample files.

### 5.3 Presets (outcome-based)

- Web images (WebP/AVIF, max 2400 px, metadata preserved minus GPS)
- Archive video (HEVC MP4, hardware, preserve tracks)
- Audio for iPhone (AAC 256k)
- Lossless audio (FLAC)
- PDF for sharing (merge, OCR optional)
- Office → Markdown
- Data cleanup (UTF-8, LF, JSON)
- Custom user presets with ⌘1–⌘9

### 5.4 Design execution

The original spec's visual direction still holds; production means executing it without web-style decoration.

- **Window:** 1100 × 720 default, 900 × 600 minimum; 230 pt sidebar, 320 pt inspector; 36 pt table rows; native split view and unified toolbar.
- **Type:** SF Pro and system text styles only. Tabular figures for sizes, durations, and hashes; SF Mono for paths and patterns.
- **Color:** semantic system colors; the accent only for selection and the primary action; status color always paired with text. Liquid Glass on macOS 27, standard materials on macOS 15–26.
- **Components:** native tables, popovers, menus, sheets, and controls. No card grids, no custom scrollbars, no decorative gradients.
- **States:** empty, importing, planning, blocked, running, paused, completed, failed, undone — each designed, with copy that names the next action.
- **Icon and brand:** one strong app icon (a sheet whose format bars snap into alignment), full macOS icon set, light/dark variants, 16 px legibility.
- **Motion:** 120–200 ms ease-out; progress updates throttled; Reduce Motion and Reduce Transparency respected.
- **QA:** screenshot matrix for light/dark and each state, Accessibility Inspector audit, VoiceOver pass, keyboard-only pass, and snapshot tests for critical views.

### 5.5 Recommended additions beyond the selected features

These are low-cost, high-value additions that fit the architecture; none blocks v1.

- **Fidelity report** — already core, and the clearest differentiator versus every GUI converter reviewed.
- **Per-file target overrides** — necessary once mixed batches are allowed; included in v1.
- **Subtitle preservation** — copy subtitle tracks on remux by default; convert SRT/VTT/ASS and burn-in can follow.
- **Image sequence ↔ video** — natural for designers and VFX users; schedule after video lands.
- **CLI and Shortcuts** — a small `fileformatter` CLI over the same engine is cheap once the core is stable and makes the app scriptable.
- **Archive intake** — converting files inside ZIP/7z without extracting is useful, but it is a different safety model; keep it out of v1.
- **Metadata editor** — currently preserve/strip; authoring metadata is a later pro feature.

---

## 6. Architecture

### 6.1 Layers

```
┌─────────────────────────────────────────────────────────────────────┐
│ SwiftUI app: navigation, queue, inspector, reports, watch, dupes    │
│   @Observable AppModel · @MainActor state · Swift 6 concurrency     │
├─────────────────────────────────────────────────────────────────────┤
│ ConversionCoordinator (actor)                                       │
│   plan → validate → schedule → execute → journal → report            │
│   Backends: ImageIO · AVFoundation · PDFKit/Vision · FFmpeg · Rust   │
├─────────────────────────────────────────────────────────────────────┤
│ Rust core (static archive, UniFFI)                                 │
│   detect · capability catalog · plan · rename · hash · data · office│
├─────────────────────────────────────────────────────────────────────┤
│ Native engines                                                      │
│   ImageIO/CoreImage · AVFoundation/VideoToolbox · PDFKit · Vision    │
│   Bundled LGPL FFmpeg (subprocess) for containers/codecs Apple lacks │
├─────────────────────────────────────────────────────────────────────┤
│ Persistence: SQLite journal + JSON presets + security-scoped books  │
└─────────────────────────────────────────────────────────────────────┘
```

**Division of responsibility**

- **Rust** owns deterministic logic that benefits from speed, portability, and strong tests: magic-byte detection, the capability graph, plan generation, rename templates, collision resolution, hashing/deduplication, data-format conversion, OOXML extraction, and fidelity prediction.
- **Swift** owns everything that touches Apple frameworks or the UI: metadata probing, image/audio/video/PDF conversion, Vision OCR, watch folders, notifications, and execution scheduling.
- **FFmpeg** is a bundled, LGPL-only subprocess used where AVFoundation cannot read or write the container/codec. It is never the default path for formats Apple handles natively.

### 6.2 Rust core

Crate layout:

```
rust/
├─ Cargo.toml                 # workspace, release profile tuned
├─ core/                      # detect, catalog, plan, rename, hash
├─ data/                      # csv/json/yaml/toml/xlsx
├─ office/                    # docx/pptx/xlsx (zip + quick-xml + calamine)
├─ ffi/                       # UniFFI surface
└─ tests/                     # fixtures + property tests
```

**FFI design:** UniFFI 0.32.x, **synchronous only**. Async UniFFI is not `Sendable`-clean under Swift 6 and has no built-in cancellation; the synchronous path is mature, maps errors to Swift `throws`, and frees `Arc` objects in `deinit`. Long operations are chunked per file and check a cancellation flag between chunks, so the Swift actor remains in control.

```text
detect_file(path) -> FileKind
build_plan(inputs: [ProbedFile], recipe: Recipe, destination: Destination) -> Plan
rename_preview(names, pattern, options) -> [RenameResult]
hash_files(paths) -> [HashResult]                  // BLAKE3, chunked, cancellable
find_duplicates(paths) -> [DuplicateGroup]
convert_data(input, output, options) -> ConversionResult
extract_office(input, output, options) -> OfficeResult
```

`ProbedFile` comes from Swift (dimensions, duration, codecs, streams, color info). Rust does not call AVFoundation. Every FFI entry point is wrapped in `catch_unwind`; the crate keeps `panic = "unwind"` so a panic becomes a Swift error instead of terminating the app. This keeps the boundary honest and testable.

### 6.3 Swift conversion engine

- `ProbeService`: UTType + ImageIO/AVFoundation/PDFKit/ffprobe, cached, cancellable.
- `ConversionCoordinator` actor: bounded concurrency per family (images/data 8, audio 4, video 2), priority, pause/cancel, retry.
- `Backend` protocol with implementations:
  - `ImageBackend` — ImageIO/CoreImage for JPEG/PNG/HEIC/AVIF/TIFF/GIF/RAW; libwebp for WebP encode/decode/animation; SVG via resvg in Rust.
  - `MediaBackend` — AudioToolbox for audio; AVFoundation `AVAssetReader/Writer` and VideoToolbox for video; tracks/subtitles; HEVC tagged `hvc1`.
  - `PDFBackend` — PDFKit/CoreGraphics; merge/split/extract/render; Vision OCR text layer.
  - `FFmpegBackend` — Process, argument array (no shell), `-progress pipe:1`, temp output, SIGTERM cancellation.
  - `RustBackend` — data/office conversions via FFI.
- `OutputWriter`: temp file in the destination volume → fsync → atomic replace; journal entry before and after; collision revalidation at write time. Rust's static library is linked into the app (no embedded dylib), so only the app and the bundled FFmpeg helpers are signed.
- `Journal`: SQLite (WAL) with runs, items, recoveries, watches; powers Undo and crash recovery.
- `UndoService`: outputs to Trash, replaced originals restored from the recovery store; verifies files before touching them.

### 6.4 FFmpeg strategy

- Build an **LGPL-2.1-only** FFmpeg (no `--enable-gpl`, `--enable-nonfree`, `--enable-version3`, no x264/x265). H.264/HEVC encoding uses VideoToolbox; AV1 encoding uses SVT-AV1; Opus/Vorbis/MP3/FLAC use their libraries. Image WebP is handled by libwebp (BSD) rather than FFmpeg.
- The Homebrew FFmpeg on this Mac is a GPL build and must never be bundled. The build script compiles the LGPL configuration from a pinned source release.
- Bundle `ffmpeg` and `ffprobe` inside `Contents/Helpers`, signed inside-out with the app and given the `com.apple.security.inherit` entitlement so the sandboxed parent can hand them file access. Invoke with an argument array and a scrubbed environment; force `-tag:v hvc1` on HEVC output.
- Provide `COPYING.LGPLv2.1`, the FFmpeg license notice, the exact configure line, and a source offer in the app and repository. For private use this is conservative; if the app is ever distributed widely, switch to dynamically linked LGPL libraries with relinkable objects or revisit licensing with counsel.
- Never depend on Homebrew at runtime.

### 6.5 Capability registry

A single Rust table describes every supported edge:

```text
(input family, input type, output type) -> {
  engine, lossless: bool, options, preserves: [streams, metadata, alpha, ...],
  drops: [...], min_os, estimated_cost
}
```

The Swift UI reads it through FFI. This is what makes "anything to anything" maintainable: adding a format is a data change plus an engine test, not a UI rewrite.

### 6.6 Persistence and recovery

- `~/Library/Application Support/FileFormatter/`:
  - `journal.sqlite` (WAL) — runs, items, hashes, recovery paths.
  - `recoveries/<run-id>/` — replaced originals, moved not copied when possible.
  - `presets.json`, `watches.json`.
- Security-scoped bookmarks for watch folders and chosen destinations.
- Recovery retention 30 days / 10 GB, oldest-first eviction; Undo disabled with a stated reason when files are gone.

### 6.7 Concurrency and performance

- Swift 6 strict concurrency; UI state `@MainActor`; engines are actors; `AsyncStream` for progress.
- No file I/O on the main thread; metadata streams in as it is probed.
- Rust parallelism via Rayon for hashing; calls are chunked per file so Swift cancellation is honored between batches; streaming parsers for CSV/JSON/XLSX; no whole-file buffering for media.
- Video: stream copy when possible; hardware decode/encode; temp files on the destination volume.
- Bounded memory: image processing in tiles where possible; cap concurrent video jobs; autorelease pools.
- Signposts (`OSSignposter`) around probe, plan, execute, write; benchmark script enforces budgets.

### 6.8 Security

- Content-based detection; extension mismatch is a warning, not a crash.
- Zip/XML limits for Office files (entry count, uncompressed size, compression ratio); no DTD/XXE.
- FFmpeg arguments sanitized; no shell; paths passed as arrays.
- Temp files 0600, cleaned on launch and cancel.
- The M0 private build is unsandboxed: same-folder output requires directory access that a file-scoped sandbox grant does not provide. `Config/FileFormatter.entitlements` is reserved for a future sandboxed build with an explicit output-folder grant.
- When sandboxing returns, security-scoped bookmarks cover watch folders and destinations, and bundled helpers carry `com.apple.security.inherit`.
- No network entitlement, no analytics, no uploads.
- PDF JavaScript is never executed; OCR is local.
- Resource guards: image pixel limits, memory pressure handling, disk-space preflight.

---

## 7. Apple-native workflow

Following Apple's current guidance (Xcode 27 / Swift 6.4):

- **Project:** one Xcode app target + local Swift packages. The committed `.xcodeproj` is generated from `project.yml` by XcodeGen, and the app folder is managed by the project generator. `RustBridge` links a **static** Rust archive through a small C module target. A static XCFramework with SwiftPM `binaryTarget` was evaluated but SwiftPM did not expose the archive's Clang module reliably; the C-target link is deterministic and adds no signing surface.
- **Language:** Swift 6 language mode, complete strict concurrency, `@Observable`, structured concurrency, no detached tasks without a lifetime.
- **UI:** SwiftUI app lifecycle, `NavigationSplitView`, `.inspector`, `Table`, `Settings`, `MenuBarExtra`, `dropDestination`, `fileImporter`, standard panels.
- **System integration:** App Intents for Shortcuts, Services menu, `SMAppService` for optional launch-at-login, `UNUserNotificationCenter`, `NSWorkspace` Trash APIs.
- **Tests:** Swift Testing for units and integration; XCTest for UI and performance; Rust `cargo test` + property tests; golden fixture matrix; one shared `.xctestplan` covering formats, appearances, and accessibility.
- **Quality tools:** Instruments (Time Profiler, Allocations, File Activity), Accessibility Inspector, VoiceOver, String Catalogs, `xcodebuild analyze`. A `PrivacyInfo.xcprivacy` is optional here: required-reason declarations currently apply to other Apple platforms, not macOS, and this app collects nothing.
- **Signing:** ad-hoc (`CODE_SIGN_IDENTITY=-`), no notarization for the private build. Xcode disables Hardened Runtime when signing ad-hoc; it is enabled as soon as a Developer ID exists. The Rust code is a static archive inside the app binary, so it adds no signing surface. Helpers will be signed inside-out when FFmpeg lands. Sandboxing is deferred (D-004).
- **macOS 27 design:** Xcode 27 adopts Liquid Glass automatically and removes the old-design opt-out; the UI is designed for macOS 26/27 with Liquid Glass and current SwiftUI APIs, with no legacy fallback.
- **Packaging:** `xcodebuild archive` → `.app` → signed DMG; version and build numbers from `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`.
- **Build settings:** release WMO, dead-code stripping, symbol stripping with a dSYM archive, `SWIFT_STRICT_CONCURRENCY=complete`, hardened runtime, no network entitlement. Rust uses `lto="fat"`, `codegen-units=1`, `strip="symbols"` for distribution, and DWARF + `dsymutil` for symbolicated crashes; never `-C target-cpu=native`.

### 7.1 Repository layout

```
FileFormatter/
├─ FileFormatter.xcodeproj
├─ App/                         # SwiftUI app target (synchronized folder)
│  ├─ App/                      # entry, state, commands, menu bar
│  ├─ Features/                 # Convert, Watch, Duplicates, History, Settings
│  ├─ DesignSystem/             # tokens, components, icon assets
│  └─ Resources/                # Assets, String Catalog, PrivacyInfo, entitlements
├─ Packages/
│  ├─ FileFormatterCore/        # models, capability types, journal
│  ├─ FileFormatterConversion/  # probe, backends, coordinator, undo
│  ├─ FileFormatterUI/          # reusable views
│  └─ FileFormatterRust/        # static archive + UniFFI wrapper
├─ rust/                        # cargo workspace
├─ vendor/ffmpeg/               # build scripts, licenses (binaries generated)
├─ scripts/                     # bootstrap, build, test, bench, release
├─ Tests/                       # fixtures + golden expectations
├─ docs/                        # spec, plan, fidelity matrix, decisions
├─ Makefile
└─ README.md
```

### 7.2 Build pipeline

```bash
make doctor        # verify Xcode, Rust, SDK, and source pins
make bootstrap     # build the Rust static archive + bindings, generate the project
make bootstrap-media  # build LGPL FFmpeg helpers (needed from M3)
make build         # xcodebuild (Debug)
make test          # cargo test + swift test + xcodebuild test
make bench         # conversion benchmarks + signpost summary
make release       # archive, ad-hoc sign, DMG, checksums
```

Artifacts (`Vendor/`, `.build/`, DMGs) are gitignored; the bootstrap is reproducible from source pins.

---

## 8. Delivery plan

Estimates are focused working days for one experienced macOS engineer, assuming the architecture above. Parallel subagents reduce elapsed time, not total integration effort.

### M0 — Foundation (2–3 days)

- Xcode project, Swift packages, Rust workspace, static archive + UniFFI bindings, build scripts.
- FFmpeg LGPL build script scaffolded (binaries land in M3, when media needs them).
- Capability registry v0 with images.
- App shell: sidebar, empty state, queue table, inspector skeleton, design tokens.
- CI-style `make test`, first golden conversion (PNG → JPEG/WebP), logging.

**Gate:** `make bootstrap && make build` produces a signed app that converts an image with atomic output and a journal entry. **Met 18 Oct 2026:** `make test` passes the Rust tests, Swift tests, app build, and the in-bundle self-test (plan → convert → journal → undo).

### M1 — Universal queue, images, PDF, data (in progress)

- Full queue UX: mixed families, per-family targets, per-file override, preview, fidelity badges.
- Image engine: formats, resize, profiles, metadata, animation; SVG; RAW.
- PDF: images ↔ PDF, merge/split, extract, rotate, text extraction.
- Data: CSV/TSV/JSON/YAML/TOML/XLSX; Office text extraction (DOCX/PPTX → MD/TXT/HTML).
- Journal, undo, collision handling, fidelity report, presets, history.

**Gate:** 12 mixed fixtures convert with predicted outcomes; undo round-trips; golden tests pass; light/dark screenshots of the empty, queue, inspector, and fidelity report states are reviewed.

### M2 — Audio (3–4 days)

- Native/FFmpeg routing, bitrate/sample-rate/channels, metadata/art/chapters.
- Format matrix, fidelity prediction, presets.
- Long-file progress/cancel; malformed-file behavior.

**Gate:** MP3/AAC/FLAC/WAV/OGG/Opus conversions; lossless chain verified; metadata preserved.

### M3 — Video (8–12 days)

- Probe (streams, HDR, subtitles, chapters), remux, transcode, hardware H.264/HEVC.
- Track/subtitle selection and preservation; GIF/image-sequence extraction.
- Progress/ETA, cancellation, disk-space checks, large-file handling.
- Fidelity report with stream maps.

**Gate:** MP4/MOV/MKV/WebM remux and transcode; 4K hardware encode; cancel leaves no temp files; report matches output.

### M4 — OCR, searchable PDF, quick actions (4–5 days)

- Vision OCR, page rendering, invisible text layer, language selection.
- Services/App Intents/Shortcuts, menu-bar drop target, notifications.
- Office extraction polish and XLSX round-trip.

**Gate:** OCR produces searchable PDFs; Finder/Shortcuts conversions land in history and are undoable.

### M5 — Watch folders and duplicates (4–5 days)

- FSEvents watcher, stability/debounce, rules, pause, launch-at-login.
- Duplicate finder: size prefilter, BLAKE3, keep-one workflow, Trash + undo.
- Watch-run idempotency and crash recovery.

**Gate:** dropping a file into a watched folder converts once, not twice; duplicate scan on 10k files stays responsive.

### M6 — Hardening and release (4–6 days)

- Performance pass against budgets, memory/disk stress, 1,000-file queues.
- Accessibility audit, keyboard-only flow, VoiceOver, reduced motion, high contrast.
- Error copy, empty states, onboarding, app icon, final design polish.
- Fuzz/robustness corpus, diagnostics export, README, licenses, DMG.

**Gate:** release checklist complete; DMG installs on a clean Mac and converts each family; no P0/P1 defects.

**Total:** roughly 31–43 focused days. With parallel research/implementation, expect several calendar weeks, not a weekend.

---

## 9. Parallel workstreams

To use subagents without merge chaos, I will freeze the interfaces first, then fan out into disjoint directories:

| Stream | Scope | Owns |
|---|---|---|
| **A. Rust core** | detect, catalog, plan, rename, hash, data, office, tests | `rust/` |
| **B. UI/design** | shell, queue, inspector, presets, history, empty states, tokens | `App/`, `Packages/FileFormatterUI` |
| **C. Native engines** | image, PDF, probe, output writer, undo | `Packages/FileFormatterConversion` |
| **D. Media** | audio, video, FFmpeg backend, subtitles | `Packages/FileFormatterConversion/Media` |
| **E. Automation** | OCR, watch folders, duplicates, menu bar, quick actions | feature folders + services |
| **F. QA/release** | fixtures, golden tests, benchmarks, packaging, docs | `Tests/`, `scripts/`, `docs/` |

Rules: no agent edits another stream's directory; shared types live in `FileFormatterCore` and change only through a reviewed interface commit; every stream ships tests with its code.

---

## 10. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Scope explosion ("anything to anything") | Never ships | Capability graph + staged milestones; v1 matrix is explicit; additions are data + tests |
| Video edge cases (HDR, Dolby Vision, odd containers) | Bad output or crashes | Remux-first; copy HDR metadata; refuse unsupported conversions with a clear reason rather than degrade silently |
| FFmpeg licensing/patents when sharing | Legal exposure | LGPL-2.1-only build, no GPL encoders, notices + source offer; private use; revisit before broad distribution |
| HEVC compatibility (`hev1` vs `hvc1`) | Output that QuickTime/AVFoundation refuses to decode | Always tag `hvc1`; verify with AVAssetReader in golden tests |
| WebP encode unavailable from ImageIO | Missing promised output | Bundle libwebp (BSD), not a workaround |
| Native Office expectations | Users expect layout fidelity | Clearly label Office extraction as text/images; no Office → PDF promise |
| PDF "compression" quality | Rasterized text, angry users | Ship merge/split/render/OCR first; rasterizing compression is labeled and opt-in |
| Rust/FFI build fragility | Slow builds, link errors | Static archive built by `bootstrap`; synchronous UniFFI surface; `catch_unwind`; `make test` smoke test |
| UniFFI async/Swift 6 friction | Data races or compile failures | Sync API only; long work chunked with cooperative cancellation; no CFType graphs across FFI |
| Watch folder duplicate runs | Repeated conversions | Stability checks, content-hash dedupe per rule, journaled watch events |
| OCR accuracy / large PDFs | Memory spikes, disappointment | Page-at-a-time rendering, cancellation, confidence display, "text layer only" option |
| Ad-hoc signing friction | Friends see Gatekeeper warnings | Document right-click → Open; optional Developer ID later |
| Large-file disk pressure | Failed jobs, full disk | Preflight output estimate ×1.2, temp-on-destination, cancel cleanup, disk guard |

---

## 11. Assumptions to confirm

1. **Minimum macOS 26** — confirmed: every target Mac runs 26/27, so no legacy fallbacks are needed.
2. **Watch folders only run while the app is open** (menu bar), with optional launch-at-login. A background helper/agent is out of scope for v1.
3. **English UI**, structured for localization; OCR auto-detects languages (English/Indonesian included).
4. **FFmpeg is bundled** (~40–60 MB), so the app lands around 80–120 MB. This matches comparable converters.
5. **No auto-update** in v1; a new build is copied over the old one. Sparkle can be added later.
6. **Unsandboxed for the private build.** Same-folder output needs directory access that a file-scoped sandbox grant does not provide. Sandboxing returns with an explicit output-folder grant or broader distribution. This is recorded as D-004.
6. **Private-use licensing**: the app itself can stay unlicensed/MIT; third-party notices are included.

---

## 12. Immediate next actions after approval

1. Scaffold the repository, Xcode project, Rust workspace, and build scripts (M0).
2. Prove the spine end-to-end: PNG → WebP with preview, atomic write, journal, undo, fidelity badge.
3. Add the second backend (PDF) and the capability registry, then start parallel streams.
4. Set up the fixture corpus and performance harness before adding breadth.

If this plan is approved, I will start with M0 and keep the app runnable after every milestone.

---

## Appendix A — Research inputs

- Product landscape and feature bar: Permute 4, HandBrake, ffWorks, Compressor, Dropzone, Transnomino, Yoink, ImageOptim; pricing and review evidence gathered October 2026. Key finding: **verification and workflow safety are the defensible gap**, not raw format count.
- Apple workflow: [Xcode system requirements](https://developer.apple.com/xcode/system-requirements), [local packages](https://developer.apple.com/documentation/xcode/organizing-your-code-with-local-packages), [App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox), [accessing files from the sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox), [Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime), [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [NSServices](https://developer.apple.com/documentation/bundleresources/information-property-list/nsservices), [App Intents](https://developer.apple.com/documentation/appintents), [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice), [Swift Testing](https://developer.apple.com/documentation/testing), [macOS 27 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes).
- Verified locally: Xcode 27.1 / Swift 6.4 / macOS 27.0.1 / Rust 1.95; `sips` writes HEIC, AVIF, JPEG, PNG, TIFF and GIF on this machine but **not WebP**, and the Homebrew FFmpeg build has no WebP encoder. WebP therefore requires bundled libwebp. AudioToolbox natively lists MP3, AAC, ALAC, FLAC, Opus, Vorbis, WAV and AIFF, which reduces how much audio must go through FFmpeg.
- Codec/licensing findings: [FFmpeg legal](https://ffmpeg.org/legal.html), [libwebp](https://github.com/webmproject/libwebp), [Audiotoolbox formats](https://developer.apple.com/documentation/audiotoolbox), [AVFoundation file types](https://developer.apple.com/documentation/avfoundation/avfiletype), [PDFKit](https://developer.apple.com/documentation/pdfkit), [WebKit PDF](https://developer.apple.com/documentation/webkit/wkwebview/createpdf(configuration:completionhandler:)). MP3 patents expired and Fraunhofer ended its program; MP3 encoding is not a licensing blocker. HEVC tagged `hev1` fails AVFoundation decode; use `hvc1`. libheif is LGPL-3.0 and unnecessary because HEIC encode is native.
- Rust integration: [static XCFramework](https://developer.apple.com/documentation/xcode/creating-a-multi-platform-binary-framework-bundle), [SwiftPM binary targets](https://developer.apple.com/documentation/xcode/distributing-binary-frameworks-as-swift-packages), [UniFFI Swift overview](https://mozilla.github.io/uniffi-rs/latest/swift/overview.html), [UniFFI futures limitation](https://mozilla.github.io/uniffi-rs/latest/futures.html), [Panic handling in Rust 1.81+](https://blog.rust-lang.org/2024/09/05/Rust-1.81.0/). Reference implementation: [jayjay](https://github.com/hewigovens/jayjay).
- The plan intentionally uses UniFFI synchronously and keeps codecs in Swift: proven by shipping apps, whereas async UniFFI cancellation and Rust-owned Apple codecs remain experimental.
