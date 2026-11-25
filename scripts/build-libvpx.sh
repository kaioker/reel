#!/bin/zsh
# Builds libvpx (VP9 / VP8 decoding, including transparent WebM) from the WebM project's source as a static
# library for macOS 13 and later. Linked into Reel's FFmpeg libraries and its bundled ffmpeg, so Reel runs on
# every macOS it says it supports (a package-manager copy is built for the newest macOS only). Decoders only.
#
# Output: ~/Library/Caches/reel-ffmpeg-build/vpx-static/{include,lib} — rebuilt when the version or options change.
set -e
VER=1.17.0
SHA256=1020f184046187baa2985dbde38e0691f49c44088bca7a1842b0236c6081dc0a
MIN_MACOS=13.0
OPTS=(--target=arm64-darwin22-gcc --enable-static --disable-shared --enable-pic
      --disable-examples --disable-tools --disable-docs --disable-unit-tests
      --disable-vp8-encoder --disable-vp9-encoder --enable-vp9-highbitdepth)

DEPS="$HOME/Library/Caches/reel-ffmpeg-build"     # space-free (configure scripts can't cope with spaces)
OUT="$DEPS/vpx-static"
CONFIG="$VER|$MIN_MACOS|${OPTS[*]}"
if [[ -f "$OUT/lib/libvpx.a" && "$(cat "$OUT/.config" 2>/dev/null)" == "$CONFIG" ]]; then
  echo "libvpx $VER already built: $OUT"; exit 0
fi
mkdir -p "$DEPS"

TAR="$DEPS/libvpx-$VER.tar.gz"
sum() { shasum -a 256 "$1" | cut -d' ' -f1 }
if [[ ! -f "$TAR" || "$(sum "$TAR")" != "$SHA256" ]]; then
  echo "Downloading libvpx $VER source from the WebM project…"
  curl -fL --progress-bar -o "$TAR" "https://github.com/webmproject/libvpx/archive/refs/tags/v$VER.tar.gz"
fi
[[ "$(sum "$TAR")" == "$SHA256" ]] || { echo "The libvpx download doesn't match its published checksum — not using it."; exit 1; }

SRC="$DEPS/libvpx-src"
rm -rf "$SRC"; mkdir -p "$SRC/build"
tar -C "$SRC" -xzf "$TAR"
cd "$SRC/build"
"../libvpx-$VER/configure" --prefix="$SRC/prefix" "${OPTS[@]}" \
  --extra-cflags="-mmacosx-version-min=$MIN_MACOS" --extra-cxxflags="-mmacosx-version-min=$MIN_MACOS"
make -j"$(sysctl -n hw.ncpu)"
make install

# every object must be built for macOS 13 (the linker only warns otherwise)
NEWER=$(otool -l "$SRC/prefix/lib/libvpx.a" | awk '/minos/ { if ($2 + 0 > '"${MIN_MACOS%%.*}"') n++ } END { print n + 0 }')
[[ "$NEWER" == 0 ]] || { echo "libvpx has $NEWER objects built for a newer macOS than $MIN_MACOS"; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT/lib"
cp "$SRC/prefix/lib/libvpx.a" "$OUT/lib/"
cp -R "$SRC/prefix/include" "$OUT/"
echo "$CONFIG" > "$OUT/.config"
echo "Built libvpx $VER for macOS $MIN_MACOS+ → $OUT"
