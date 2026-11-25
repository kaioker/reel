import AppKit
import AVFoundation
import Accelerate
import CFFmpeg

/// In-app decoding with FFmpeg's libraries, for what macOS can't play itself: transparent WebM (VP9 / VP8
/// with alpha, via libvpx) and video encodings Apple's decoders reject. Frames and audio are handed to
/// macOS's own sample-buffer renderers, kept in step by an AVSampleBufferRenderSynchronizer — so playback
/// starts right away, with no converting.
final class FFBackend: NSObject, PlayerBackend {
    weak var delegate: BackendDelegate?
    var autoplay = true
    let hasVideo = true

    private let host = SampleBufferView()
    var view: NSView { host }
    private var display: AVSampleBufferDisplayLayer { host.display }
    fileprivate let audio = AVSampleBufferAudioRenderer()
    fileprivate let clock = AVSampleBufferRenderSynchronizer()

    private var session: FFSession?
    private var tick: Timer?
    private var wantPlaying = false
    private var clockStarted = false
    private var endReported = false
    fileprivate(set) var startOffset: Double = 0
    private(set) var duration: Double = 0
    private var volume: Float = 1
    var rate: Float = 1 { didSet { if wantPlaying && clockStarted { clock.rate = rate } } }
    private var url: URL?
    private var fps: Double = 30
    /// The file's audio streams (FFmpeg stream index, name) and the one playing.
    private var audioStreams: [(index: Int32, name: String)] = []
    private var currentAudio: Int32 = -1
    /// The video is being decoded by the Mac's media engine (VideoToolbox) rather than the processor.
    fileprivate(set) var decodingOnHardware = false

    override init() {
        super.init()
        audio.audioTimePitchAlgorithm = .spectral
        if #available(macOS 14.0, *) { clock.addRenderer(display.sampleBufferRenderer) } else { clock.addRenderer(display) }
        clock.addRenderer(audio)
    }

    var currentTime: Double {
        let t = clock.currentTime().seconds - startOffset
        return t.isFinite ? max(0, min(t, duration > 0 ? duration : t)) : 0
    }
    var isPlaying: Bool { wantPlaying }
    var debugAudioRendering: String {
        switch audio.status { case .rendering: return "rendering"; case .failed: return "failed: \(audio.error?.localizedDescription ?? "")"; default: return "idle" }
    }

    // MARK: PlayerBackend

    func load(_ track: Track) {
        guard let url = track.url else { delegate?.backendFailed("Bad URL"); return }
        start(url: url)
    }

    func start(url: URL, audioStream: Int32? = nil, at time: Double? = nil) {
        self.url = url
        if audioStream == nil { audioStreams = []; currentAudio = -1 }
        decodingOnHardware = false
        stopSession()
        flushRenderers()
        clock.setRate(0, time: .zero)
        clockStarted = false
        endReported = false
        duration = 0
        startOffset = 0
        wantPlaying = autoplay
        let s = FFSession(url: url.isFileURL ? url.path : url.absoluteString, owner: self, audioStream: audioStream)
        session = s
        s.start()
        if let time { clock.setRate(0, time: CMTime(seconds: time, preferredTimescale: 90_000)); s.requestSeek(to: time) }
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.onTick() }
    }

    func play() {
        wantPlaying = true
        if clockStarted { clock.rate = rate }
        delegate?.backendStateChanged()
    }

    func pause() {
        wantPlaying = false
        clock.rate = 0
        delegate?.backendStateChanged()
    }

    func seek(to seconds: Double) {
        guard let s = session else { return }
        let t = max(0, min(seconds, duration > 0 ? duration - 0.05 : seconds))
        endReported = false
        // Hold the clock at the target until the new frames are in (the session restarts it).
        clockStarted = false
        clock.setRate(0, time: CMTime(seconds: t + startOffset, preferredTimescale: 90_000))
        s.requestSeek(to: t + startOffset)
        delegate?.backendTick()
    }

    func setVolume(_ v: Float) { volume = v; audio.volume = v }

    func step(frames: Int) {
        pause()
        seek(to: max(0, currentTime + Double(frames) / max(1, fps)))
    }

    var audioTrackNames: [String] { audioStreams.count > 1 ? audioStreams.map(\.name) : [] }
    var selectedAudioTrack: Int { audioStreams.firstIndex { $0.index == currentAudio } ?? 0 }
    /// Restarts decoding from the same spot with the other audio stream.
    func selectAudioTrack(_ i: Int) {
        guard i >= 0, i < audioStreams.count, audioStreams[i].index != currentAudio, let url else { return }
        let t = currentTime + startOffset, playing = wantPlaying
        let keep = audioStreams
        autoplay = playing
        start(url: url, audioStream: keep[i].index, at: t)
        audioStreams = keep
        currentAudio = keep[i].index
    }

    func stop() {
        stopSession()
        tick?.invalidate(); tick = nil
        clock.rate = 0
        flushRenderers()
        wantPlaying = false
    }

    private func stopSession() {
        session?.cancel()
        session = nil
    }

    // MARK: Called by the session

    fileprivate func isCurrent(_ s: FFSession) -> Bool {
        // read from the decode thread; session is only replaced on main, a stale read just drops a frame
        session === s
    }

    fileprivate func flushRenderers() {
        if #available(macOS 14.0, *) { display.sampleBufferRenderer.flush() } else { display.flush() }
        audio.flush()
    }

    fileprivate func enqueueVideo(_ sb: CMSampleBuffer) {
        if #available(macOS 14.0, *) { display.sampleBufferRenderer.enqueue(sb) } else { display.enqueue(sb) }
    }

    fileprivate func opened(duration d: Double, start: Double, size: CGSize, alpha: Bool,
                            fps f: Double, audio list: [(index: Int32, name: String)], playingAudio: Int32) {
        duration = d
        startOffset = start
        fps = f
        audioStreams = list
        currentAudio = playingAudio
        delegate?.backendTracksChanged()
        if session?.pendingSeekValue == nil { clock.setRate(0, time: CMTime(seconds: start, preferredTimescale: 90_000)) }
        host.setTransparent(alpha)
        if size.width > 0 { delegate?.backendVideoSize(size) }
        delegate?.backendTransparent(alpha)
        delegate?.backendStateChanged()
    }

    /// The session has buffered enough after opening or seeking: let time run (if playing).
    fileprivate func bufferReady(at t: Double) {
        clockStarted = true
        clock.setRate(wantPlaying ? rate : 0, time: CMTime(seconds: t, preferredTimescale: 90_000))
        delegate?.backendStateChanged()
        delegate?.backendTick()
    }

    fileprivate func failed(_ msg: String) { delegate?.backendFailed(msg) }

    private func onTick() {
        delegate?.backendTick()
        guard let s = session, s.reachedEnd, !endReported, duration > 0 || s.lastPTS > 0 else { return }
        let end = (s.lastPTS > 0 ? s.lastPTS - startOffset : duration) - 0.08
        if currentTime >= end {
            endReported = true
            delegate?.backendDidEnd()
        }
    }
}

/// Layer-hosting view for the sample-buffer display layer.
final class SampleBufferView: NSView {
    let display = AVSampleBufferDisplayLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = display
        wantsLayer = true
        display.videoGravity = .resizeAspect
        setTransparent(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    func setTransparent(_ t: Bool) {
        display.backgroundColor = (t ? NSColor.clear : NSColor.black).cgColor
        display.isOpaque = !t
    }
}

// MARK: - Decode session (one per file; runs on its own thread)

private final class FFSession {
    let url: String
    weak var owner: FFBackend?
    private let lock = NSLock()
    private var cancelled = false
    private var pendingSeek: Double?
    private(set) var reachedEnd = false
    private(set) var lastPTS: Double = 0

    private var fmt: UnsafeMutablePointer<AVFormatContext>?
    private var vctx: UnsafeMutablePointer<AVCodecContext>?
    private var actx: UnsafeMutablePointer<AVCodecContext>?
    private var vIndex: Int32 = -1, aIndex: Int32 = -1
    private var vtb = AVRational(num: 1, den: 1), atb = AVRational(num: 1, den: 1)
    private var sws: UnsafeMutablePointer<SwsContext>?
    private var swr: OpaquePointer?
    private var swrInRate: Int32 = 0
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private var videoFormat: CMVideoFormatDescription?
    /// VideoToolbox (the Mac's media engine), shared by this session's video decoder.
    private var hwDevice: UnsafeMutablePointer<AVBufferRef>?
    /// Frames are coming from the hardware decoder.
    private(set) var hardwareFrames = false
    private var alpha = false
    private var dropBefore: Double = -1
    private var lastVideoPTS: Double = -1, lastAudioPTS: Double = -1
    private var bufferStartedAt: Double = -1
    private var waitingForBuffer = true

    private let audioChoice: Int32?
    init(url: String, owner: FFBackend, audioStream: Int32?) { self.url = url; self.owner = owner; self.audioChoice = audioStream }
    var pendingSeekValue: Double? { lock.lock(); defer { lock.unlock() }; return pendingSeek }

    func start() {
        let t = Thread { [self] in run() }
        t.name = "Reel FFmpeg decoder"
        t.qualityOfService = .userInitiated
        t.start()
    }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func requestSeek(to t: Double) { lock.lock(); pendingSeek = t; lock.unlock() }
    private func takeSeek() -> Double? { lock.lock(); defer { lock.unlock() }; let s = pendingSeek; pendingSeek = nil; return s }

    private func onMain(_ body: @escaping (FFBackend) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let o = self.owner, !self.isCancelled, o.isCurrent(self) else { return }
            body(o)
        }
    }

    // MARK: Run loop

    private func run() {
        defer { cleanup() }
        guard open() else { return }
        let pkt = av_packet_alloc()
        defer { var p = pkt; av_packet_free(&p) }

        while !isCancelled {
            if let t = takeSeek() { doSeek(t) }

            // keep about a second buffered ahead of the clock
            if aheadOfClock() > 1.0 && !waitingForBuffer { usleep(8_000); continue }
            if reachedEnd { usleep(20_000); continue }

            let r = av_read_frame(fmt, pkt)
            if r < 0 {
                drain()
                reachedEnd = true
                lastPTS = max(lastVideoPTS, lastAudioPTS)
                if waitingForBuffer { readyIfBuffered(force: true) }
                continue
            }
            if pkt!.pointee.stream_index == vIndex, let vctx { decode(pkt, with: vctx, video: true) }
            else if pkt!.pointee.stream_index == aIndex, let actx { decode(pkt, with: actx, video: false) }
            av_packet_unref(pkt)
        }
    }

    private func aheadOfClock() -> Double {
        guard let o = owner else { return 0 }
        let now = o.clock.currentTime().seconds
        let latest = vIndex >= 0 ? lastVideoPTS : lastAudioPTS
        return latest - now
    }

    private func readyIfBuffered(force: Bool = false) {
        guard waitingForBuffer else { return }
        let latest = max(lastVideoPTS, lastAudioPTS)
        let haveVideo = vIndex < 0 || lastVideoPTS >= 0
        let haveAudio = aIndex < 0 || lastAudioPTS >= 0
        if force || (haveVideo && haveAudio && latest - bufferStartedAt >= 0.25) {
            waitingForBuffer = false
            let t = bufferStartedAt
            onMain { $0.bufferReady(at: t) }
        }
    }

    // MARK: Open

    private func open() -> Bool {
        var opts: OpaquePointer?
        if url.hasPrefix("http") {
            av_dict_set(&opts, "user_agent", MediaResolver.browserUA, 0)
            av_dict_set(&opts, "reconnect", "1", 0)
        }
        var ctx: UnsafeMutablePointer<AVFormatContext>?
        let r = avformat_open_input(&ctx, url, nil, &opts)
        av_dict_free(&opts)
        guard r >= 0, let ctx else { fail("Couldn't open this file"); return false }
        fmt = ctx
        guard avformat_find_stream_info(ctx, nil) >= 0 else { fail("Couldn't read this file"); return false }

        vIndex = av_find_best_stream(ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        aIndex = av_find_best_stream(ctx, AVMEDIA_TYPE_AUDIO, -1, vIndex, nil, 0)
        // every audio stream, named by its title / language, so you can switch
        var audioList: [(index: Int32, name: String)] = []
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let st = ctx.pointee.streams[i], st.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO else { continue }
            func tag(_ k: String) -> String? { av_dict_get(st.pointee.metadata, k, nil, 0).map { String(cString: $0.pointee.value) } }
            let lang = tag("language").flatMap { $0 == "und" ? nil : Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
            var parts = [tag("title"), lang].compactMap { $0 }.filter { !$0.isEmpty }
            if parts.count == 2, parts[0].localizedCaseInsensitiveContains(parts[1]) { parts.removeLast() }   // "English · English"
            let name = parts.joined(separator: " · ")
            audioList.append((Int32(i), name.isEmpty ? "Track \(audioList.count + 1)" : name))
        }
        if let c = audioChoice, audioList.contains(where: { $0.index == c }) { aIndex = c }
        var fps = 30.0
        if vIndex < 0 && aIndex < 0 { fail("No video or audio in this file"); return false }

        var size = CGSize.zero
        if vIndex >= 0, let st = ctx.pointee.streams[Int(vIndex)] {
            let par = st.pointee.codecpar!
            // Transparent VP9/VP8 WebM marks alpha_mode=1; only libvpx decodes the alpha plane.
            let alphaTag = av_dict_get(st.pointee.metadata, "alpha_mode", nil, 0).map { String(cString: $0.pointee.value) } == "1"
            var codec: UnsafePointer<AVCodec>?
            if alphaTag && par.pointee.codec_id == AV_CODEC_ID_VP9 { codec = avcodec_find_decoder_by_name("libvpx-vp9") }
            if alphaTag && par.pointee.codec_id == AV_CODEC_ID_VP8 { codec = avcodec_find_decoder_by_name("libvpx") }
            if codec == nil { codec = avcodec_find_decoder(par.pointee.codec_id) }
            alpha = alphaTag && codec != nil
            // Hardware first (not for transparent video: VideoToolbox drops the alpha plane), software if it can't.
            vctx = (alpha ? nil : openHardwareDecoder(codec, par)) ?? openDecoder(codec, par)
            vtb = st.pointee.time_base
            size = CGSize(width: Int(par.pointee.width), height: Int(par.pointee.height))
            let fr = st.pointee.avg_frame_rate
            if fr.num > 0 && fr.den > 0 { fps = Double(fr.num) / Double(fr.den) }
            if vctx == nil { vIndex = -1 }
        }
        if aIndex >= 0, let st = ctx.pointee.streams[Int(aIndex)] {
            actx = openDecoder(avcodec_find_decoder(st.pointee.codecpar.pointee.codec_id), st.pointee.codecpar)
            atb = st.pointee.time_base
            if actx == nil { aIndex = -1 }
        }
        if vIndex < 0 && aIndex < 0 { fail("Reel can't decode this format"); return false }

        let tb = Double(reel_time_base())
        let dur = ctx.pointee.duration > 0 ? Double(ctx.pointee.duration) / tb : 0
        let st0 = ctx.pointee.start_time != reel_nopts() ? Double(ctx.pointee.start_time) / tb : 0
        bufferStartedAt = st0
        let a = alpha, playingAudio = aIndex, f = fps
        onMain { $0.opened(duration: dur, start: st0, size: size, alpha: a, fps: f, audio: audioList, playingAudio: playingAudio) }
        return true
    }

    private func openDecoder(_ codec: UnsafePointer<AVCodec>?, _ par: UnsafeMutablePointer<AVCodecParameters>?) -> UnsafeMutablePointer<AVCodecContext>? {
        guard let codec, var c = avcodec_alloc_context3(codec) else { return nil }
        avcodec_parameters_to_context(c, par)
        c.pointee.thread_count = 0
        if avcodec_open2(c, codec, nil) < 0 { var p: UnsafeMutablePointer<AVCodecContext>? = c; avcodec_free_context(&p); return nil }
        _ = c
        return c
    }

    /// A decoder that hands frames to VideoToolbox, if this codec can use it (nil: decode in software).
    private func openHardwareDecoder(_ codec: UnsafePointer<AVCodec>?, _ par: UnsafeMutablePointer<AVCodecParameters>?) -> UnsafeMutablePointer<AVCodecContext>? {
        guard let codec, ProcessInfo.processInfo.environment["REEL_SOFTWARE_DECODE"] == nil else { return nil }
        var i: Int32 = 0, supported = false
        while let cfg = avcodec_get_hw_config(codec, i) {
            if cfg.pointee.device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX && Int(cfg.pointee.methods) & Int(AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) != 0 {
                supported = true; break
            }
            i += 1
        }
        guard supported else { return nil }
        if hwDevice == nil, av_hwdevice_ctx_create(&hwDevice, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) < 0 { return nil }
        guard var c = avcodec_alloc_context3(codec) else { return nil }
        avcodec_parameters_to_context(c, par)
        c.pointee.hw_device_ctx = av_buffer_ref(hwDevice)
        reel_use_videotoolbox_format(c)
        if avcodec_open2(c, codec, nil) < 0 { var p: UnsafeMutablePointer<AVCodecContext>? = c; avcodec_free_context(&p); return nil }
        _ = c
        return c
    }

    private func fail(_ msg: String) { onMain { $0.failed(msg) } }

    // MARK: Seek

    private func doSeek(_ t: Double) {
        let ts = Int64(t * Double(reel_time_base()))
        av_seek_frame(fmt, -1, ts, AVSEEK_FLAG_BACKWARD)
        if let vctx { avcodec_flush_buffers(vctx) }
        if let actx { avcodec_flush_buffers(actx) }
        reachedEnd = false
        dropBefore = t
        lastVideoPTS = -1; lastAudioPTS = -1
        bufferStartedAt = t
        waitingForBuffer = true
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { [weak self] in self?.owner?.flushRenderers(); sem.signal() }
        sem.wait()
    }

    // MARK: Decode

    private func decode(_ pkt: UnsafeMutablePointer<AVPacket>?, with ctx: UnsafeMutablePointer<AVCodecContext>, video: Bool) {
        guard avcodec_send_packet(ctx, pkt) >= 0 || pkt == nil else { return }
        guard let frame = av_frame_alloc() else { return }
        defer { var f: UnsafeMutablePointer<AVFrame>? = frame; av_frame_free(&f) }
        while !isCancelled {
            let r = avcodec_receive_frame(ctx, frame)
            if r == reel_err_again() || r == reel_err_eof() || r < 0 { break }
            if video { emitVideo(frame) } else { emitAudio(frame) }
            av_frame_unref(frame)
        }
        readyIfBuffered()
    }

    private func drain() {
        if let vctx { decode(nil, with: vctx, video: true) }
        if let actx { decode(nil, with: actx, video: false) }
    }

    private func seconds(_ ts: Int64, _ tb: AVRational) -> Double {
        ts == reel_nopts() ? -1 : Double(ts) * Double(tb.num) / Double(tb.den)
    }

    private func emitVideo(_ f: UnsafeMutablePointer<AVFrame>) {
        let t = seconds(f.pointee.best_effort_timestamp, vtb)
        guard t >= 0, t >= dropBefore - 0.001 else { return }
        // Decoded by VideoToolbox: the frame already is a CVPixelBuffer the display layer can show as-is.
        if f.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue, let raw = f.pointee.data.3 {
            let pb = Unmanaged<CVPixelBuffer>.fromOpaque(UnsafeRawPointer(raw)).takeUnretainedValue()
            if !hardwareFrames { hardwareFrames = true; onMain { $0.decodingOnHardware = true } }
            enqueue(pb, at: t)
            return
        }
        let w = Int(f.pointee.width), h = Int(f.pointee.height)
        guard w > 0, h > 0, let pb = makePixelBuffer(w, h) else { return }

        sws = sws_getCachedContext(sws, Int32(w), Int32(h), AVPixelFormat(rawValue: f.pointee.format),
                                   Int32(w), Int32(h), AV_PIX_FMT_BGRA, Int32(SWS_BILINEAR.rawValue), nil, nil, nil)
        guard let sws else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let stride = Int32(CVPixelBufferGetBytesPerRow(pb))
        var dst: [UnsafeMutablePointer<UInt8>?] = [base, nil, nil, nil]
        var dstStride: [Int32] = [stride, 0, 0, 0]
        withUnsafePointer(to: &f.pointee.data) { dp in
            dp.withMemoryRebound(to: UnsafePointer<UInt8>?.self, capacity: 8) { src in
                withUnsafePointer(to: &f.pointee.linesize) { lp in
                    lp.withMemoryRebound(to: Int32.self, capacity: 8) { srcStride in
                        _ = sws_scale(sws, src, srcStride, 0, Int32(h), &dst, &dstStride)
                    }
                }
            }
        }
        if alpha {
            // CoreAnimation expects premultiplied alpha
            var buf = vImage_Buffer(data: base, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: Int(stride))
            vImagePremultiplyData_RGBA8888(&buf, &buf, vImage_Flags(kvImageNoFlags))   // alpha is last either way
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        enqueue(pb, at: t)
    }

    private func enqueue(_ pb: CVPixelBuffer, at t: Double) {
        if videoFormat == nil || !CMVideoFormatDescriptionMatchesImageBuffer(videoFormat!, imageBuffer: pb) {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &videoFormat)
        }
        guard let videoFormat else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(seconds: t, preferredTimescale: 90_000), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: videoFormat, sampleTiming: &timing, sampleBufferOut: &sb)
        guard let sb, let o = owner, o.isCurrent(self), !isCancelled else { return }
        o.enqueueVideo(sb)
        lastVideoPTS = t
    }

    private func makePixelBuffer(_ w: Int, _ h: Int) -> CVPixelBuffer? {
        if pool == nil || poolSize != CGSize(width: w, height: h) {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            poolSize = CGSize(width: w, height: h)
        }
        var pb: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) }
        return pb
    }

    private func emitAudio(_ f: UnsafeMutablePointer<AVFrame>) {
        let t = seconds(f.pointee.best_effort_timestamp, atb)
        guard t >= 0, t >= dropBefore - 0.05 else { return }
        let rate = f.pointee.sample_rate
        if swr == nil || rate != swrInRate {
            if swr != nil { swr_free(&swr) }
            var outLayout = AVChannelLayout()
            av_channel_layout_default(&outLayout, 2)
            var s: OpaquePointer?
            let r = withUnsafePointer(to: &f.pointee.ch_layout) { inLayout in
                swr_alloc_set_opts2(&s, &outLayout, AV_SAMPLE_FMT_FLT, rate, inLayout,
                                    AVSampleFormat(rawValue: f.pointee.format), rate, 0, nil)
            }
            guard r >= 0, let s, swr_init(s) >= 0 else { return }
            swr = s; swrInRate = rate
        }
        let inCount = f.pointee.nb_samples
        let maxOut = Int(inCount) + 256
        var out = [Float](repeating: 0, count: maxOut * 2)
        let produced: Int32 = out.withUnsafeMutableBytes { raw in
            var outPtr: UnsafeMutablePointer<UInt8>? = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            return withUnsafePointer(to: &outPtr) { op in
                let inData = UnsafeRawPointer(f.pointee.extended_data!).assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
                return swr_convert(swr, op, Int32(maxOut), inData, inCount)
            }
        }
        guard produced > 0 else { return }

        var asbd = AudioStreamBasicDescription(mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var fmtDesc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &fmtDesc)
        let bytes = Int(produced) * 8
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
        guard let block, let fmtDesc else { return }
        out.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: fmtDesc,
                                                             sampleCount: CMItemCount(produced),
                                                             presentationTimeStamp: CMTime(seconds: t, preferredTimescale: CMTimeScale(rate)),
                                                             packetDescriptions: nil, sampleBufferOut: &sb)
        guard let sb, let o = owner, o.isCurrent(self), !isCancelled else { return }
        o.audio.enqueue(sb)
        lastAudioPTS = t + Double(produced) / Double(rate)
    }

    // MARK: Cleanup

    private func cleanup() {
        if vctx != nil { avcodec_free_context(&vctx) }
        if actx != nil { avcodec_free_context(&actx) }
        if fmt != nil { avformat_close_input(&fmt) }
        if sws != nil { sws_freeContext(sws); sws = nil }
        if swr != nil { swr_free(&swr) }
        if hwDevice != nil { av_buffer_unref(&hwDevice) }
    }
}
