#!/bin/zsh
# Builds FFmpeg's decoding libraries as shared libraries for Reel's in-app decoder (no converting needed).
# They ship in Reel.app/Contents/Frameworks as separate, replaceable files (LGPL v2.1; no GPL parts).
# libvpx (VP9/VP8 incl. transparency) is linked into libavcodec statically.
#
# Needs: Xcode Command Line Tools, brew install libvpx. Uses the FFmpeg source that scripts/build-ffmpeg.sh
# downloads (official tarball). Output: .deps/ffmpeg-shared/{include,lib} (cached; rebuilt automatically
# when the configuration below changes, or delete it to rebuild).
# Subtitles: the text formats (SubRip, WebVTT, ASS/SSA, MP4 timed text) and picture subtitles (Blu-ray PGS,
# DVD, DVB) are decoded here, for subtitle files and subtitles inside MKV / MP4 files.
set -e
cd "$(dirname "$0")/.."
VER=9.0.2
OUT="$PWD/.deps/ffmpeg-shared"
DEMUXERS=mov,matroska,webm_dash_manifest,mp3,aac,wav,aiff,flac,ogg,mpegts,avi,ivf,srt,webvtt,ass
DECODERS=vp9,vp8,libvpx_vp9,libvpx_vp8,h264,hevc,av1,mpeg4,mpeg2video,prores,mjpeg,aac,mp3,mp3float,opus,vorbis,flac,alac,ac3,eac3,pcm_s16le,pcm_s24le,pcm_f32le,pcm_s16be,subrip,srt,ass,ssa,webvtt,movtext,text,pgssub,dvdsub,dvbsub
PARSERS=vp9,vp8,h264,hevc,av1,aac,mpegaudio,opus,vorbis,flac,ac3,dvdsub,dvbsub
CONFIG="$VER|$DEMUXERS|$DECODERS|$PARSERS"
if [[ -f "$OUT/lib/libavcodec.dylib" && "$(cat "$OUT/.config" 2>/dev/null)" == "$CONFIG" ]]; then
  echo "FFmpeg libraries already built: $OUT"; exit 0
fi

# FFmpeg's configure can't cope with spaces in paths, so build in a space-free cache folder.
DEPS="$HOME/Library/Caches/reel-ffmpeg-build"
mkdir -p "$DEPS"
if [[ ! -d "$DEPS/ffmpeg-$VER" ]]; then
  echo "Downloading FFmpeg $VER source from ffmpeg.org…"
  curl -fL --progress-bar -o "$DEPS/ffmpeg-$VER.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz"
  tar -C "$DEPS" -xf "$DEPS/ffmpeg-$VER.tar.xz"
fi
VPX=$(brew --prefix libvpx 2>/dev/null || echo /opt/homebrew/opt/libvpx)
[[ -f "$VPX/lib/libvpx.a" ]] || { echo "Need libvpx: brew install libvpx"; exit 1; }
rm -rf "$DEPS/vpx-static"; mkdir -p "$DEPS/vpx-static/lib"; cp "$VPX/lib/libvpx.a" "$DEPS/vpx-static/lib/"; cp -R "$VPX/include" "$DEPS/vpx-static/"

PREFIX="$DEPS/shared-prefix"
# A separate, clean copy of the source (FFmpeg can't build a second configuration from a source tree
# that already has one, and scripts/build-ffmpeg.sh builds the ffmpeg tool in the first copy).
BUILD="$DEPS/src-shared"
rm -rf "$BUILD" "$PREFIX"; mkdir -p "$BUILD"
tar -C "$BUILD" -xf "$DEPS/ffmpeg-$VER.tar.xz"
cd "$BUILD/ffmpeg-$VER"
./configure --prefix="$PREFIX" --install-name-dir='@rpath' \
  --disable-everything --disable-autodetect --disable-doc --disable-debug --disable-programs \
  --enable-shared --disable-static --enable-pthreads \
  --enable-securetransport --enable-zlib --enable-libvpx \
  --extra-cflags="-I$DEPS/vpx-static/include -mmacosx-version-min=13.0" \
  --extra-ldflags="-L$DEPS/vpx-static/lib -mmacosx-version-min=13.0" \
  --enable-avformat --enable-avcodec --enable-avutil --enable-swscale --enable-swresample \
  --disable-avfilter --disable-avdevice \
  --enable-protocol=file,pipe,http,https,tcp,tls,crypto,cache \
  --enable-demuxer=$DEMUXERS \
  --enable-decoder=$DECODERS \
  --enable-parser=$PARSERS \
  --enable-bsf=vp9_superframe,vp9_superframe_split,extract_extradata
# configure quietly skips names it doesn't know (e.g. "mov_text" instead of "movtext"): check each one is on
for pair in DEMUXER:$DEMUXERS DECODER:$DECODERS PARSER:$PARSERS; do
  kind=${pair%%:*}
  for n in ${(s:,:)${pair#*:}}; do
    grep -q "#define CONFIG_${(U)n}_${kind} 1" config_components.h || { echo "FFmpeg didn't enable $kind '$n' — check the name"; exit 1; }
  done
done
make -j"$(sysctl -n hw.ncpu)"
make install
rm -rf "$OUT"; mkdir -p "$OUT"
cp -R "$PREFIX/include" "$OUT/"
mkdir -p "$OUT/lib"
cp -a "$PREFIX/lib/"*.dylib "$OUT/lib/"
echo "$CONFIG" > "$OUT/.config"
echo "Built FFmpeg libraries → $OUT/lib"
ls -la "$OUT/lib"
