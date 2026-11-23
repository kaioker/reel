#!/bin/zsh
# Builds the small, self-contained ffmpeg that ships inside Reel.app (Contents/Helpers/ffmpeg).
# Only what Reel uses: VP9 (incl. transparency via libvpx) / H.264 / HEVC / AV1 decoding, Apple's hardware
# HEVC encoder, MP4/MOV/WebM/MKV, web downloads over HTTPS. LGPL build (no GPL parts).
#
# Needs: Xcode Command Line Tools, and libvpx's static library (brew install libvpx) — linked in statically,
# so the result only depends on macOS itself. Output: .deps/ffmpeg-bin/ffmpeg (cached; delete to rebuild).
set -e
cd "$(dirname "$0")/.."
VER=9.0.2
OUT="$PWD/.deps/ffmpeg-bin"
[[ -x "$OUT/ffmpeg" ]] && { echo "ffmpeg already built: $OUT/ffmpeg"; exit 0; }
mkdir -p "$OUT"
# FFmpeg's configure can't cope with spaces in paths (this project lives in "Reel Player"),
# so the build happens in a space-free cache folder and only the finished binary is copied back.
DEPS="$HOME/Library/Caches/reel-ffmpeg-build"
mkdir -p "$DEPS"

# libvpx: link the static archive only (a folder with just libvpx.a, so the linker can't pick the .dylib)
VPX=$(brew --prefix libvpx 2>/dev/null || echo /opt/homebrew/opt/libvpx)
[[ -f "$VPX/lib/libvpx.a" ]] || { echo "Need libvpx: brew install libvpx"; exit 1; }
rm -rf "$DEPS/vpx-static"; mkdir -p "$DEPS/vpx-static/lib"; cp "$VPX/lib/libvpx.a" "$DEPS/vpx-static/lib/"; cp -R "$VPX/include" "$DEPS/vpx-static/"

cd "$DEPS"
if [[ ! -d "ffmpeg-$VER" ]]; then
  echo "Downloading FFmpeg $VER source from ffmpeg.org…"
  curl -fL --progress-bar -o "ffmpeg-$VER.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$VER.tar.xz"
  tar xf "ffmpeg-$VER.tar.xz"
fi
cd "ffmpeg-$VER"

./configure --prefix="$DEPS/prefix" \
  --disable-everything --disable-autodetect --disable-doc --disable-debug \
  --disable-ffplay --disable-ffprobe --enable-ffmpeg \
  --enable-static --disable-shared --enable-pthreads \
  --enable-videotoolbox --enable-audiotoolbox --enable-securetransport --enable-zlib \
  --enable-libvpx \
  --extra-cflags="-I$DEPS/vpx-static/include -mmacosx-version-min=13.0" \
  --extra-ldflags="-L$DEPS/vpx-static/lib -mmacosx-version-min=13.0" \
  --enable-protocol=file,pipe,http,https,tcp,tls,crypto,cache \
  --enable-demuxer=mov,matroska,webm_dash_manifest,mp3,aac,wav,aiff,flac,ogg,mpegts,avi,hls,ivf \
  --enable-decoder=vp9,vp8,libvpx_vp9,libvpx_vp8,h264,hevc,av1,mpeg4,mpeg2video,prores,mjpeg,aac,mp3,mp3float,opus,vorbis,flac,alac,ac3,eac3,pcm_s16le,pcm_s24le,pcm_f32le,pcm_s16be \
  --enable-encoder=hevc_videotoolbox,h264_videotoolbox,aac,aac_at \
  --enable-muxer=mov,mp4,null \
  --enable-parser=vp9,vp8,h264,hevc,av1,aac,mpegaudio,opus,vorbis,flac,ac3 \
  --enable-bsf=vp9_superframe,vp9_superframe_split,h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc,extract_extradata \
  --enable-filter=buffer,buffersink,abuffer,abuffersink,format,aformat,scale,aresample,null,anull,setpts,asetpts,trim,atrim,copy,acopy \
  --enable-swscale --enable-swresample

make -j"$(sysctl -n hw.ncpu)" ffmpeg
cp ffmpeg "$OUT/ffmpeg"
strip "$OUT/ffmpeg" 2>/dev/null || true
echo "Built $OUT/ffmpeg"
