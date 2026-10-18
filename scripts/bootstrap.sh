#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RUST_TARGET="aarch64-apple-darwin"
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
cp "$RUST_DIR/target/$RUST_TARGET/release/libfileformatter_core.a" \
   "$PACKAGE_RUST/Vendor/libfileformatter_core.a"

echo "==> Generating the Xcode project"
xcodegen generate

echo "bootstrap complete"
