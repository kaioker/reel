import AppKit
import CFFmpeg

/// One subtitle event: text, or a picture (Blu-ray / DVD subtitles) placed on the video frame.
struct SubtitleCue {
    var start: Double
    var end: Double
    var text: String?
    var image: CGImage?
    /// Where the picture goes, in the subtitle's own frame (`frame`, usually the video's pixel size).
    var imageRect: CGRect = .zero
    var frame: CGSize = .zero
}

/// Reads subtitles with FFmpeg's demuxers and subtitle decoders: subtitle files (.srt, .vtt, .ass, .ssa) and
/// subtitle streams inside video files (MKV, MP4). Text comes out as plain text; picture subtitles as images.
enum SubtitleReader {
    struct Stream {
        let index: Int32
        let name: String
        let isPicture: Bool
    }

    static let fileExtensions: Set<String> = ["srt", "vtt", "ass", "ssa"]

    /// The subtitle streams in a file (a subtitle file has one).
    static func streams(in url: URL) -> [Stream] {
        guard let ctx = open(url) else { return [] }
        defer { var c: UnsafeMutablePointer<AVFormatContext>? = ctx; avformat_close_input(&c) }
        var out: [Stream] = []
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let st = ctx.pointee.streams[i], st.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE else { continue }
            let id = st.pointee.codecpar.pointee.codec_id
            guard avcodec_find_decoder(id) != nil else { continue }          // a format Reel can't decode
            func tag(_ k: String) -> String? { av_dict_get(st.pointee.metadata, k, nil, 0).map { String(cString: $0.pointee.value) } }
            let lang = tag("language").flatMap { $0 == "und" ? nil : Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
            var parts = [tag("title"), lang].compactMap { $0 }.filter { !$0.isEmpty }
            if parts.count == 2, parts[0].localizedCaseInsensitiveContains(parts[1]) { parts.removeLast() }
            if st.pointee.disposition & AV_DISPOSITION_FORCED != 0 { parts.append("forced") }
            let name = parts.isEmpty ? "Subtitles \(out.count + 1)" : parts.joined(separator: " · ")
            out.append(Stream(index: Int32(i), name: name, isPicture: isPicture(id)))
        }
        return out
    }

    /// Every event of one subtitle stream (nil: the first one), on the video's timeline.
    static func read(_ url: URL, stream: Int32? = nil, isCancelled: () -> Bool = { false }) -> [SubtitleCue] {
        guard let ctx = open(url) else { return [] }
        defer { var c: UnsafeMutablePointer<AVFormatContext>? = ctx; avformat_close_input(&c) }
        let n = Int(ctx.pointee.nb_streams)
        let index: Int = {
            if let s = stream { return Int(s) }
            return (0..<n).first { ctx.pointee.streams[$0]?.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE } ?? -1
        }()
        guard index >= 0, index < n, let st = ctx.pointee.streams[index] else { return [] }
        // only the subtitle stream: the demuxer skips everything else
        for i in 0..<n where i != index { ctx.pointee.streams[i]?.pointee.discard = AVDISCARD_ALL }

        let par = st.pointee.codecpar!
        guard let codec = avcodec_find_decoder(par.pointee.codec_id), var dec = avcodec_alloc_context3(codec) else { return [] }
        defer { var d: UnsafeMutablePointer<AVCodecContext>? = dec; avcodec_free_context(&d) }
        avcodec_parameters_to_context(dec, par)
        dec.pointee.pkt_timebase = st.pointee.time_base
        guard avcodec_open2(dec, codec, nil) >= 0 else { return [] }
        _ = dec

        // picture subtitles are positioned on the video frame: use the video's size when the decoder doesn't say
        var videoSize = CGSize(width: Int(par.pointee.width), height: Int(par.pointee.height))
        if videoSize.width == 0, let v = (0..<n).compactMap({ ctx.pointee.streams[$0] }).first(where: { $0.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO }) {
            videoSize = CGSize(width: Int(v.pointee.codecpar.pointee.width), height: Int(v.pointee.codecpar.pointee.height))
        }
        let tb = st.pointee.time_base
        let startOffset = ctx.pointee.start_time != reel_nopts() ? Double(ctx.pointee.start_time) / Double(reel_time_base()) : 0

        var cues: [SubtitleCue] = []
        let pkt = av_packet_alloc()
        defer { var p = pkt; av_packet_free(&p) }
        while !isCancelled(), av_read_frame(ctx, pkt) >= 0 {
            defer { av_packet_unref(pkt) }
            guard pkt!.pointee.stream_index == Int32(index) else { continue }
            var sub = AVSubtitle()
            var got: Int32 = 0
            guard avcodec_decode_subtitle2(dec, &sub, &got, pkt) >= 0, got != 0 else { continue }
            defer { avsubtitle_free(&sub) }
            let pts = pkt!.pointee.pts != reel_nopts() ? pkt!.pointee.pts : pkt!.pointee.dts
            guard pts != reel_nopts() else { continue }
            let base = Double(pts) * Double(tb.num) / Double(tb.den) - startOffset
            let start = base + Double(sub.start_display_time) / 1000
            var end: Double = .nan
            if sub.end_display_time > sub.start_display_time && sub.end_display_time != UInt32.max {
                end = base + Double(sub.end_display_time) / 1000
            } else if pkt!.pointee.duration > 0 {
                end = base + Double(pkt!.pointee.duration) * Double(tb.num) / Double(tb.den)
            }
            let frame = dec.pointee.width > 0 ? CGSize(width: Int(dec.pointee.width), height: Int(dec.pointee.height)) : videoSize
            if sub.num_rects == 0 {
                // a picture-subtitle "clear": ends whatever was showing
                cues.append(SubtitleCue(start: start, end: start))
                continue
            }
            var texts: [String] = []
            for r in 0..<Int(sub.num_rects) {
                guard let rect = sub.rects[r]?.pointee else { continue }
                switch rect.type {
                case SUBTITLE_ASS:
                    if let a = rect.ass { texts.append(plainText(fromASS: String(cString: a))) }
                case SUBTITLE_TEXT:
                    if let t = rect.text { texts.append(String(cString: t)) }
                case SUBTITLE_BITMAP:
                    if let img = image(rect) {
                        cues.append(SubtitleCue(start: start, end: end, image: img,
                                                imageRect: CGRect(x: Int(rect.x), y: Int(rect.y), width: Int(rect.w), height: Int(rect.h)),
                                                frame: frame))
                    }
                default: break
                }
            }
            let text = texts.filter { !$0.isEmpty }.joined(separator: "\n")
            if !text.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: text)) }
        }
        return finish(cues)
    }

    // MARK: Helpers

    private static func open(_ url: URL) -> UnsafeMutablePointer<AVFormatContext>? {
        var opts: OpaquePointer?
        if !url.isFileURL { av_dict_set(&opts, "user_agent", MediaResolver.browserUA, 0) }
        var ctx: UnsafeMutablePointer<AVFormatContext>?
        let path = url.isFileURL ? url.path : url.absoluteString
        let r = avformat_open_input(&ctx, path, nil, &opts)
        av_dict_free(&opts)
        guard r >= 0, let ctx else { return nil }
        guard avformat_find_stream_info(ctx, nil) >= 0 else { var c: UnsafeMutablePointer<AVFormatContext>? = ctx; avformat_close_input(&c); return nil }
        return ctx
    }

    private static func isPicture(_ id: AVCodecID) -> Bool {
        id == AV_CODEC_ID_HDMV_PGS_SUBTITLE || id == AV_CODEC_ID_DVD_SUBTITLE || id == AV_CODEC_ID_DVB_SUBTITLE
    }

    /// Sorts the events and fills in end times the format leaves open (picture subtitles end at the next event).
    private static func finish(_ raw: [SubtitleCue]) -> [SubtitleCue] {
        let cues = raw.sorted { $0.start < $1.start }
        var out: [SubtitleCue] = []
        for (i, c) in cues.enumerated() {
            var c = c
            if c.text == nil && c.image == nil { continue }                     // "clear" markers only end others
            if !c.end.isFinite || c.end <= c.start {
                let next = cues[(i + 1)...].first { $0.start > c.start }?.start
                c.end = min(next ?? c.start + 5, c.start + (c.image != nil ? 30 : 8))
            }
            out.append(c)
        }
        return out
    }

    /// FFmpeg hands text subtitles over as ASS dialogue: "ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text".
    /// Keeps the Text, without styling overrides ({\i1} …), with ASS line breaks as real ones.
    static func plainText(fromASS line: String) -> String {
        var text = Substring(line)
        for _ in 0..<8 { guard let c = text.firstIndex(of: ",") else { break }; text = text[text.index(after: c)...] }
        var out = "", depth = 0
        for ch in text {
            if ch == "{" { depth += 1; continue }
            if ch == "}" { depth = max(0, depth - 1); continue }
            if depth == 0 { out.append(ch) }
        }
        return out.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A palettized picture subtitle (8-bit indices + RGBA palette) as a CGImage.
    private static func image(_ r: AVSubtitleRect) -> CGImage? {
        let w = Int(r.w), h = Int(r.h)
        guard w > 0, h > 0, let idx = r.data.0, let palRaw = r.data.1 else { return nil }
        let stride = Int(r.linesize.0)
        let pal = UnsafeRawPointer(palRaw).assumingMemoryBound(to: UInt32.self)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let c = pal[Int(idx[y * stride + x])]                 // 0xAARRGGBB
                let a = UInt8(c >> 24), rr = UInt8((c >> 16) & 0xff), g = UInt8((c >> 8) & 0xff), b = UInt8(c & 0xff)
                let o = (y * w + x) * 4
                // premultiplied RGBA
                px[o] = UInt8(UInt16(rr) * UInt16(a) / 255); px[o + 1] = UInt8(UInt16(g) * UInt16(a) / 255)
                px[o + 2] = UInt8(UInt16(b) * UInt16(a) / 255); px[o + 3] = a
            }
        }
        let data = Data(px) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Draws the current subtitle over the video: text along the bottom of the picture (scaled to the video's size,
/// white with a soft dark backing so it reads on anything), or a picture subtitle where the film puts it.
final class SubtitleOverlay: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let picture = NSImageView()
    private var cue: SubtitleCue?
    /// The video's shape, to work out where the picture sits inside this view.
    var videoAspect: CGFloat = 16.0 / 9 { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.alignment = .center
        label.textColor = .white
        label.maximumNumberOfLines = 0
        label.wantsLayer = true
        label.drawsBackground = true
        label.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        label.isHidden = true
        let sh = NSShadow(); sh.shadowColor = .black; sh.shadowBlurRadius = 3; sh.shadowOffset = .zero
        label.shadow = sh
        picture.imageScaling = .scaleAxesIndependently
        picture.isHidden = true
        [picture, label].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    var debugText: String? { cue.map { $0.text ?? "(picture)" } }

    func show(_ c: SubtitleCue?) {
        if c?.start == cue?.start && c?.text == cue?.text && c?.image === cue?.image { return }
        cue = c
        if let img = c?.image { picture.image = NSImage(cgImage: img, size: .zero) }
        label.isHidden = c?.text == nil
        picture.isHidden = c?.image == nil
        needsLayout = true
    }

    private var videoRect: CGRect {
        let b = bounds
        guard videoAspect > 0, b.width > 0, b.height > 0 else { return b }
        if b.width / b.height > videoAspect {
            let w = b.height * videoAspect; return CGRect(x: (b.width - w) / 2, y: 0, width: w, height: b.height)
        }
        let h = b.width / videoAspect; return CGRect(x: 0, y: (b.height - h) / 2, width: b.width, height: h)
    }

    override func layout() {
        super.layout()
        let v = videoRect
        if let c = cue, let text = c.text {
            let size = max(11, min(36, v.height * 0.052))
            let para = NSMutableParagraphStyle(); para.alignment = .center
            label.attributedStringValue = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor.white, .paragraphStyle: para])
            let maxW = v.width * 0.9
            let fit = label.sizeThatFits(NSSize(width: maxW, height: .greatestFiniteMagnitude))
            let w = min(maxW, fit.width + size * 0.8), h = fit.height + size * 0.3
            label.frame = NSRect(x: v.midX - w / 2, y: v.minY + v.height * 0.06, width: w, height: h)
            label.layer?.cornerRadius = size * 0.25
        }
        if let c = cue, c.image != nil, c.frame.width > 0, c.frame.height > 0 {
            let sx = v.width / c.frame.width, sy = v.height / c.frame.height
            let r = c.imageRect                                                   // top-left origin in the subtitle frame
            picture.frame = NSRect(x: v.minX + r.minX * sx, y: v.maxY - (r.minY + r.height) * sy, width: r.width * sx, height: r.height * sy)
        }
    }
}
