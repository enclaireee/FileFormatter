# Third-party notices

## libwebp 1.6.0

- License: BSD-3-Clause
- Source: https://chromium.googlesource.com/webm/libwebp
- Use: WebP encoding (ImageIO cannot write WebP on macOS 27)
- Distribution: statically linked arm64 archive in `Packages/FileFormatterCore/Vendor/`
- Full license: `docs/licenses/libwebp-COPYING`

## UniFFI 0.32.2

- License: MPL-2.0
- Source: https://github.com/mozilla/uniffi-rs
- Use: generated Swift bindings for the Rust core

## Rust dependencies

See `rust/Cargo.lock`. Direct dependencies: `thiserror` (MIT/Apache-2.0), `uniffi` (MPL-2.0). Development: `tempfile` (MIT/Apache-2.0).

## FFmpeg

Not bundled yet. The planned LGPL-2.1 build, its exact configure line, and the source offer will be added before any audio/video build ships.
