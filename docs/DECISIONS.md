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
