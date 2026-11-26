#!/bin/zsh
# Builds FFmpeg's decoding libraries as shared libraries for Reel's in-app decoder (no converting needed).
# They ship in Reel.app/Contents/Frameworks as separate, replaceable files (LGPL v2.1; no GPL parts).
# libvpx (VP9/VP8 incl. transparency) is linked into libavcodec statically (built for macOS 13 by build-libvpx.sh).
#
# Needs: Xcode Command Line Tools. Uses the FFmpeg source that scripts/build-ffmpeg.sh
# downloads (official tarball). Output: .deps/ffmpeg-shared/{include,lib} (cached; rebuilt automatically
# when the configuration below changes, or delete it to rebuild).
# Video decodes on the Mac's media engine (VideoToolbox) where it can, in software where it can't.
# Subtitles: the text formats (SubRip, WebVTT, ASS/SSA, MP4 timed text) and picture subtitles (Blu-ray PGS,
# DVD, DVB) are decoded here, for subtitle files and subtitles inside MKV / MP4 files.
# Live and network streams: HLS, DASH (via macOS's own libxml2), RTSP (cameras), RTMP / RTMPS, UDP and RTP
# (multicast TV), and HTTP streams (MPEG-TS, MJPEG cameras, internet radio).
set -e
cd "$(dirname "$0")/.."
VER=9.0.2
OUT="$PWD/.deps/ffmpeg-shared"
DEMUXERS=mov,matroska,webm_dash_manifest,mp3,aac,wav,aiff,flac,ogg,mpegts,avi,ivf,srt,webvtt,ass,hls,dash,rtsp,sdp,rtp,flv,live_flv,mpjpeg,mjpeg
DECODERS=vp9,vp8,libvpx_vp9,libvpx_vp8,h264,hevc,av1,mpeg4,mpeg2video,prores,mjpeg,aac,mp3,mp3float,opus,vorbis,flac,alac,ac3,eac3,pcm_s16le,pcm_s24le,pcm_f32le,pcm_s16be,subrip,srt,ass,ssa,webvtt,movtext,text,pgssub,dvdsub,dvbsub,mp2,mp2float,aac_latm,pcm_mulaw,pcm_alaw,adpcm_g722,adpcm_g726
PARSERS=vp9,vp8,h264,hevc,av1,aac,mpegaudio,opus,vorbis,flac,ac3,dvdsub,dvbsub,mpegvideo,mpeg4video,mjpeg,aac_latm
# Hardware decoding through VideoToolbox (the Mac's media engine); anything it can't take decodes in software.
PROTOCOLS=file,pipe,http,https,tcp,tls,crypto,cache,data,udp,udplite,rtp,srtp,rtmp,rtmps,rtmpt,rtmpts
HWACCELS=h264_videotoolbox,hevc_videotoolbox,vp9_videotoolbox,av1_videotoolbox,mpeg2_videotoolbox,mpeg4_videotoolbox,prores_videotoolbox
./scripts/build-libvpx.sh
DEPS="$HOME/Library/Caches/reel-ffmpeg-build"
CONFIG="$VER|$DEMUXERS|$DECODERS|$PARSERS|$PROTOCOLS|$HWACCELS|libxml2|libvpx $(cat "$DEPS/vpx-static/.config")"
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

# DASH manifests are XML: parsed with the libxml2 that's part of macOS (no extra library to ship).
# FFmpeg finds it through pkg-config; this description points only at the SDK's copy, so a Homebrew libxml2
# can never be picked up instead.
SDK=$(xcrun --show-sdk-path)
command -v pkg-config >/dev/null || { echo "pkg-config is needed to build FFmpeg (brew install pkg-config)"; exit 1; }
PC="$DEPS/pkgconfig"; mkdir -p "$PC"
cat > "$PC/libxml-2.0.pc" <<PCEOF
Name: libXML
Description: libxml2 from the macOS SDK
Version: $(sed -n 's/^#define LIBXML_DOTTED_VERSION "\(.*\)"/\1/p' "$SDK/usr/include/libxml2/libxml/xmlversion.h")
Libs: -L$SDK/usr/lib -lxml2
Cflags: -I$SDK/usr/include/libxml2
PCEOF
export PKG_CONFIG_LIBDIR="$PC" PKG_CONFIG_PATH=""
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
  --enable-securetransport --enable-zlib --enable-libvpx --enable-videotoolbox --enable-libxml2 \
  --extra-cflags="-I$DEPS/vpx-static/include -mmacosx-version-min=13.0" \
  --extra-ldflags="-L$DEPS/vpx-static/lib -mmacosx-version-min=13.0" \
  --enable-avformat --enable-avcodec --enable-avutil --enable-swscale --enable-swresample \
  --disable-avfilter --disable-avdevice \
  --enable-protocol=$PROTOCOLS \
  --enable-demuxer=$DEMUXERS \
  --enable-decoder=$DECODERS \
  --enable-parser=$PARSERS \
  --enable-hwaccel=$HWACCELS \
  --enable-bsf=vp9_superframe,vp9_superframe_split,extract_extradata
# configure quietly skips names it doesn't know (e.g. "mov_text" instead of "movtext"): check each one is on
for pair in DEMUXER:$DEMUXERS DECODER:$DECODERS PARSER:$PARSERS PROTOCOL:$PROTOCOLS HWACCEL:$HWACCELS; do
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
