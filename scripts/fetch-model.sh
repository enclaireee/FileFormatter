#!/usr/bin/env bash
set -euo pipefail

# Fetches the pinned BiRefNet-lite Core ML build used for HD background removal (D-026).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URL="https://huggingface.co/metaclass/birefnet-lite-coreml/resolve/main/fp16compute-fp32io/r1/BiRefNetLite-1024-FP16Compute-FP32IO-iOS17-r1.mlpackage.zip"
SHA256="46e7f3306069d1385761c0db86d65913dc3f980bf5348eb0c3db429e3f8414b7"
BUILD="$ROOT/build/birefnet"
ZIP="$BUILD/birefnet-lite.zip"
OUT="$ROOT/vendor/birefnet"

mkdir -p "$BUILD" "$OUT"

if [ ! -f "$ZIP" ] || ! echo "$SHA256  $ZIP" | shasum -a 256 -c --status; then
  echo "==> Downloading BiRefNet-lite (about 82 MB)"
  curl -L --fail --retry 3 -o "$ZIP" "$URL"
fi
echo "$SHA256  $ZIP" | shasum -a 256 -c || { echo "error: checksum mismatch, refusing to use $ZIP"; exit 1; }

echo "==> Compiling Core ML model"
rm -rf "$BUILD/unzipped" "$OUT/BiRefNetLite.mlmodelc"
unzip -q "$ZIP" -d "$BUILD/unzipped"
cp -R "$BUILD/unzipped/BiRefNetLite-1024-FP16Compute-FP32IO.mlpackage" "$BUILD/BiRefNetLite.mlpackage"
xcrun coremlcompiler compile "$BUILD/BiRefNetLite.mlpackage" "$OUT" >/dev/null
rm -rf "$BUILD/BiRefNetLite.mlpackage"

mkdir -p "$ROOT/docs/licenses/birefnet"
cp -f "$BUILD/unzipped/"LICENSE* "$BUILD/unzipped/NOTICE" "$ROOT/docs/licenses/birefnet/"

echo "model ready: $OUT/BiRefNetLite.mlmodelc"
