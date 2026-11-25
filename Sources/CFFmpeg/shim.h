// FFmpeg's decoding libraries for Reel's in-app decoder (built by scripts/build-ffmpeg-libs.sh).
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/imgutils.h>
#include <libavutil/channel_layout.h>
#include <libavutil/dict.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>

// Macros Swift can't import directly.
static inline int reel_err_again(void) { return AVERROR(EAGAIN); }
static inline int reel_err_eof(void) { return AVERROR_EOF; }
static inline int64_t reel_nopts(void) { return AV_NOPTS_VALUE; }
static inline int reel_time_base(void) { return AV_TIME_BASE; }

// Hardware decoding: take VideoToolbox's format when the decoder offers it; otherwise (not offered, or the
// hardware can't handle this stream and FFmpeg asks again without it) the first software format.
static enum AVPixelFormat reel_pick_vt_format(AVCodecContext *ctx, const enum AVPixelFormat *fmts) {
    (void)ctx;
    for (const enum AVPixelFormat *p = fmts; *p != AV_PIX_FMT_NONE; p++)
        if (*p == AV_PIX_FMT_VIDEOTOOLBOX) return *p;
    for (const enum AVPixelFormat *p = fmts; *p != AV_PIX_FMT_NONE; p++) {
        const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(*p);
        if (d && !(d->flags & AV_PIX_FMT_FLAG_HWACCEL)) return *p;
    }
    return fmts[0];
}
static inline void reel_use_videotoolbox_format(AVCodecContext *ctx) { ctx->get_format = reel_pick_vt_format; }
