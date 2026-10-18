#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RUST_TARGET="aarch64-apple-darwin"
# Match the app so C deps (blake3) are not built for the host macOS version.
export MACOSX_DEPLOYMENT_TARGET="26.0"
BUILD_DIR="$ROOT/build"
RUST_DIR="$ROOT/rust"
PACKAGE_RUST="$ROOT/Packages/FileFormatterRust"

command -v cargo >/dev/null || { echo "error: cargo is required (Rust 1.95+)"; exit 1; }
command -v xcodegen >/dev/null || { echo "error: xcodegen is required (brew install xcodegen)"; exit 1; }

echo "==> Building Rust core for $RUST_TARGET"
cd "$RUST_DIR"
cargo build --locked --release --target "$RUST_TARGET" -p fileformatter-core

echo "==> Generating Swift bindings"
mkdir -p "$BUILD_DIR/uniffi" "$BUILD_DIR/headers"
cargo run --locked --release -q --bin uniffi-bindgen -- \
  generate \
  --library "$RUST_DIR/target/$RUST_TARGET/release/libfileformatter_core.dylib" \
  --language swift \
  --out-dir "$BUILD_DIR/uniffi"

echo "==> Vendoring libwebp (BSD-3)"
WEBP_PREFIX="$(brew --prefix webp 2>/dev/null || true)"
if [ -z "$WEBP_PREFIX" ]; then
  echo "error: webp is required (brew install webp)"; exit 1
fi
mkdir -p "$ROOT/Packages/FileFormatterCore/Vendor"
rm -f "$ROOT/Packages/FileFormatterCore/Vendor/libwebp.a"
rm -f "$ROOT/Packages/FileFormatterCore/Vendor/libsharpyuv.a"
cp "$WEBP_PREFIX/lib/libwebp.a" "$ROOT/Packages/FileFormatterCore/Vendor/"
cp "$WEBP_PREFIX/lib/libsharpyuv.a" "$ROOT/Packages/FileFormatterCore/Vendor/"
chmod u+w "$ROOT/Packages/FileFormatterCore/Vendor/"*.a

echo "==> Updating the Swift package bridge"
mkdir -p "$PACKAGE_RUST/Sources/FileFormatterRust/Generated"
mkdir -p "$PACKAGE_RUST/Sources/CFFI/include"
mkdir -p "$PACKAGE_RUST/Vendor"

rm -f "$PACKAGE_RUST/Sources/FileFormatterRust/Generated/"*.swift
cp "$BUILD_DIR/uniffi/fileformatter_core.swift" \
   "$PACKAGE_RUST/Sources/FileFormatterRust/Generated/"
cp "$BUILD_DIR/uniffi/fileformatter_coreFFI.h" \
   "$PACKAGE_RUST/Sources/CFFI/include/"
cp "$BUILD_DIR/uniffi/fileformatter_coreFFI.modulemap" \
   "$PACKAGE_RUST/Sources/CFFI/include/module.modulemap"
cp "$BUILD_DIR/uniffi/fileformatter_coreFFI.h" "$BUILD_DIR/headers/"
cp "$BUILD_DIR/uniffi/fileformatter_coreFFI.modulemap" "$BUILD_DIR/headers/"
rm -f "$PACKAGE_RUST/Vendor/libfileformatter_core.a"
cp "$RUST_DIR/target/$RUST_TARGET/release/libfileformatter_core.a" \
   "$PACKAGE_RUST/Vendor/libfileformatter_core.a"
chmod u+w "$PACKAGE_RUST/Vendor/libfileformatter_core.a"

echo "==> Generating the Xcode project"
cd "$ROOT"
xcodegen generate

echo "bootstrap complete"
