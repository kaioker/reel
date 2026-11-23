// FFmpeg's decoding libraries for Reel's in-app decoder (built by scripts/build-ffmpeg-libs.sh).
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/imgutils.h>
#include <libavutil/channel_layout.h>
#include <libavutil/dict.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>

// Macros Swift can't import directly.
static inline int reel_err_again(void) { return AVERROR(EAGAIN); }
static inline int reel_err_eof(void) { return AVERROR_EOF; }
static inline int64_t reel_nopts(void) { return AV_NOPTS_VALUE; }
static inline int reel_time_base(void) { return AV_TIME_BASE; }
