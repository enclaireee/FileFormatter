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

## Data and Office crates

- `csv` (MIT/Unlicense), `serde_json` (MIT/Apache-2.0), `serde_yaml` (MIT/Apache-2.0), `toml` (MIT/Apache-2.0)
- `zip` (MIT), `quick-xml` (MIT/Apache-2.0), `calamine` (MIT), `rust_xlsxwriter` (MIT/Apache-2.0)
- All are statically linked into the Rust core; see `rust/Cargo.lock` for exact versions.

## BiRefNet-lite (Core ML)

- License: MIT (model by ZhengPeng7; Core ML conversion by metaclass/miracle2k)
- Source: https://huggingface.co/ZhengPeng7/BiRefNet_lite (revision 7838f1c), converted build https://huggingface.co/metaclass/birefnet-lite-coreml (fp16compute-fp32io/r1)
- Use: HD background removal
- Distribution: compiled `.mlmodelc` in the app's `Resources/Models/`, fetched by `scripts/fetch-model.sh`
- Full licenses: `docs/licenses/birefnet/`

## FFmpeg 8.0.1 (LGPL-2.1-or-later)

- Source: https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz
- Build script: `scripts/build-ffmpeg.sh`
- Configuration line and build details: `vendor/ffmpeg/BUILD-INFO.txt`
- Bundled helpers: `Contents/Resources/Helpers/ffmpeg`, `ffprobe` (statically linked, LGPL-only; no `--enable-gpl`, no `--enable-nonfree`, no x264/x265)
- Codec dependencies: LAME (LGPL-2.0), Opus (BSD-3), libvorbis (BSD-3), libvpx (BSD-3), dav1d (BSD-2)
- License texts: `docs/licenses/` and the app's `Contents/Resources/Licenses/`
- Source offer: the build script and the versioned source URL satisfy the LGPL source requirement for this private build. If the app is distributed beyond friends, ship the corresponding FFmpeg source or a written offer.
