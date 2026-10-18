#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${FFMPEG_VERSION:-8.0.1}"
BUILD="$ROOT/build/ffmpeg"
PREFIX="$ROOT/vendor/ffmpeg"
TARBALL="$BUILD/ffmpeg-$VERSION.tar.xz"
SOURCE="$BUILD/ffmpeg-$VERSION"

mkdir -p "$BUILD" "$PREFIX"

if [ ! -f "$TARBALL" ]; then
  echo "==> Downloading FFmpeg $VERSION"
  curl -L --fail --retry 3 -o "$TARBALL" "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
fi

if [ ! -d "$SOURCE" ]; then
  echo "==> Extracting"
  tar -xf "$TARBALL" -C "$BUILD"
fi

cd "$SOURCE"

echo "==> Configuring LGPL-only FFmpeg"
./configure \
  --prefix="$PREFIX" \
  --disable-gpl \
  --disable-nonfree \
  --disable-version3 \
  --disable-doc \
  --disable-ffplay \
  --disable-debug \
  --enable-static \
  --disable-shared \
  --enable-videotoolbox \
  --enable-audiotoolbox \
  --enable-libmp3lame \
  --enable-libopus \
  --enable-libvorbis \
  --enable-libvpx \
  --enable-libdav1d \
  --pkg-config-flags=--static \
  --extra-cflags="-I$(brew --prefix lame)/include -I$(brew --prefix opus)/include -I$(brew --prefix libvorbis)/include -I$(brew --prefix libvpx)/include -I$(brew --prefix dav1d)/include" \
  --extra-ldflags="-L$(brew --prefix lame)/lib -L$(brew --prefix opus)/lib -L$(brew --prefix libvorbis)/lib -L$(brew --prefix libvpx)/lib -L$(brew --prefix dav1d)/lib" \
  --extra-libs="-lmp3lame"

echo "==> Building"
make -j"$(sysctl -n hw.ncpu)"
make install

echo "==> Stripping helpers"
strip -x -S "$PREFIX/bin/ffmpeg" 2>/dev/null || true
strip -x -S "$PREFIX/bin/ffprobe" 2>/dev/null || true

echo "==> Writing notices"
cp COPYING.LGPLv2.1 "$PREFIX/COPYING.LGPLv2.1" 2>/dev/null || true
cp COPYING.GPLv2 "$PREFIX/COPYING.GPLv2" 2>/dev/null || true
"$PREFIX/bin/ffmpeg" -version > "$PREFIX/BUILD-INFO.txt"
echo "FFmpeg built at $PREFIX"
