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
    var rate: Float = 1 { didSet { if wantPlaying && clockStarted { clock.rate = playRate } } }
    /// A live stream always plays at normal speed (it can't run ahead of the sender).
    private var playRate: Float { isLive ? 1 : rate }
    /// A live stream (camera, broadcast, live HLS / DASH): no end, no seeking.
    private(set) var isLive = false
    private var url: URL?
    private var fps: Double = 30
    /// The file's audio streams (FFmpeg stream index, name) and the one playing.
    private var audioStreams: [(index: Int32, name: String)] = []
    private var currentAudio: Int32 = -1
    /// The video is being decoded by the Mac's media engine (VideoToolbox) rather than the processor.
    fileprivate(set) var decodingOnHardware = false

    override init() {
        // FFmpeg's own messages (a live stream's decoder can print several a second): kept for REEL_FFLOG=<level>,
        // e.g. 48 = debug, 32 = info, 16 = errors.
        av_log_set_level(Int32(ProcessInfo.processInfo.environment["REEL_FFLOG"] ?? "") ?? 8)
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

    /// `rejoin`: playing a paused live stream again; if the source doesn't answer straight away, keep trying.
    func start(url: URL, audioStream: Int32? = nil, at time: Double? = nil, rejoin: Bool = false) {
        if url != self.url { isLive = false }        // (restarting the same live stream stays live)
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
        if debugLog { print("ff start \(url.absoluteString) audio=\(audioStream.map(String.init) ?? "-")"); fflush(stdout) }
        let s = FFSession(url: url.isFileURL ? url.path : url.absoluteString, owner: self, audioStream: audioStream, rejoin: rejoin)
        session = s
        s.start()
        if let time { clock.setRate(0, time: CMTime(seconds: time, preferredTimescale: 90_000)); s.requestSeek(to: time) }
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.onTick() }
    }

    func play() {
        // A paused live stream has fallen behind (and stopped reading): reconnect, which rejoins it live.
        if isLive, !wantPlaying, let url {
            let keep = audioStreams, a = currentAudio
            autoplay = true
            start(url: url, audioStream: a >= 0 ? a : nil, rejoin: true)
            audioStreams = keep; currentAudio = a
            delegate?.backendStateChanged()
            return
        }
        wantPlaying = true
        if clockStarted { clock.rate = playRate }
        delegate?.backendStateChanged()
    }

    func pause() {
        wantPlaying = false
        clock.rate = 0
        delegate?.backendStateChanged()
    }

    func seek(to seconds: Double) {
        guard let s = session, !isLive else { return }
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
        guard !isLive else { return }
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
        start(url: url, audioStream: keep[i].index, at: isLive ? nil : t)
        audioStreams = keep
        currentAudio = keep[i].index
    }

    func stop() {
        stopSession()
        tick?.invalidate(); tick = nil
        clock.rate = 0
        flushRenderers()
        wantPlaying = false
        isLive = false
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

    fileprivate func opened(duration d: Double, start: Double, size: CGSize, alpha: Bool, live: Bool,
                            fps f: Double, audio list: [(index: Int32, name: String)], playingAudio: Int32) {
        isLive = live
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
        clock.setRate(wantPlaying ? playRate : 0, time: CMTime(seconds: t, preferredTimescale: 90_000))
        delegate?.backendStateChanged()
        delegate?.backendTick()
    }

    /// Time is running (read from the decode thread to judge a live stream's buffer; a stale read is harmless).
    fileprivate var clockRunning: Bool { clockStarted && wantPlaying }

    /// A live stream ran dry (network stall, reconnecting): hold the picture until there's enough to go on.
    fileprivate func stalled() {
        clockStarted = false
        clock.rate = 0
    }

    /// A pushed live stream drifted ahead of the clock: jump forward to stay close to live.
    fileprivate func jumpClock(to t: Double) {
        guard clockStarted else { return }
        clock.setRate(wantPlaying ? playRate : 0, time: CMTime(seconds: t, preferredTimescale: 90_000))
    }

    fileprivate func notice(_ text: String) { delegate?.backendNotice(text) }

    fileprivate func failed(_ msg: String) { delegate?.backendFailed(msg) }

    private func onTick() {
        delegate?.backendTick()
        guard !isLive, let s = session, s.reachedEnd, !endReported, duration > 0 || s.lastPTS > 0 else { return }
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

/// Lets FFmpeg's blocking network calls give up: when the session is stopped, or a connection goes quiet.
private func ffInterrupt(_ opaque: UnsafeMutableRawPointer?) -> Int32 {
    guard let opaque else { return 0 }
    return Unmanaged<FFSession>.fromOpaque(opaque).takeUnretainedValue().shouldInterrupt ? 1 : 0
}

private final class FFSession {
    let url: String
    /// Read over the network (anything but a local file).
    private let network: Bool
    /// rtsp, rtmp, udp … (lowercased)
    private let scheme: String
    /// A live stream (found when it opens): no end, no seeking; reconnects when the connection drops.
    private var live = false
    /// Live and pushed at us at the sender's pace (camera, broadcast, multicast) rather than fetched in
    /// pieces (HLS, DASH): its buffer is watched so it stays close to live.
    private var pushed = false
    /// When a blocking network call should give up (0: no limit). Only touched on the decode thread.
    private var deadline: CFAbsoluteTime = 0
    var shouldInterrupt: Bool { isCancelled || (deadline > 0 && CFAbsoluteTimeGetCurrent() > deadline) }
    private var firstVideoPTS: Double = -1, firstAudioPTS: Double = -1
    private var aheadSince: CFAbsoluteTime = 0
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
    private let rejoin: Bool
    init(url: String, owner: FFBackend, audioStream: Int32?, rejoin: Bool) {
        self.url = url; self.owner = owner; self.audioChoice = audioStream; self.rejoin = rejoin
        network = url.contains("://") && !url.hasPrefix("file:")
        scheme = url.contains("://") ? String(url.prefix { $0 != ":" }).lowercased() : "file"
    }
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
        // rejoining a live stream: a source that's briefly not there gets the same retries as a dropped one
        guard open(quiet: rejoin) || (rejoin && reconnect()) else {
            if rejoin && !isCancelled { fail("The stream stopped (couldn't reconnect)") }
            return
        }
        let pkt = av_packet_alloc()
        defer { var p = pkt; av_packet_free(&p) }

        while !isCancelled {
            if let t = takeSeek(), !live { doSeek(t) }

            let ahead = aheadOfClock()
            if live { watchLiveBuffer(ahead) }
            // keep about a second buffered ahead of the clock (a pushed stream can run a little further
            // before it's pulled back; while paused, reading stops, and playing again reconnects)
            if ahead > (pushed ? 3.0 : live ? 1.5 : 1.0) && !waitingForBuffer { usleep(8_000); continue }
            if reachedEnd { usleep(20_000); continue }

            if live { deadline = CFAbsoluteTimeGetCurrent() + 10 }      // a live stream that goes quiet has dropped
            let r = av_read_frame(fmt, pkt)
            deadline = 0
            if r < 0 {
                if live && !isCancelled {
                    if reconnect() { continue }
                    fail("The stream stopped (couldn't reconnect)")
                    return
                }
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
        // A live stream starts from its first picture (or sound), wherever its timestamps begin.
        if live && bufferStartedAt < 0 {
            let first = vIndex >= 0 ? firstVideoPTS : firstAudioPTS
            guard first >= 0 else { return }
            bufferStartedAt = first
        }
        let latest = max(lastVideoPTS, lastAudioPTS)
        let haveVideo = vIndex < 0 || lastVideoPTS >= 0
        let haveAudio = aIndex < 0 || lastAudioPTS >= 0
        // live: a little more in hand, to ride out network jitter
        if force || (haveVideo && haveAudio && latest - bufferStartedAt >= (live ? 0.8 : 0.25)) {
            waitingForBuffer = false
            let t = bufferStartedAt
            onMain { $0.bufferReady(at: t) }
        }
    }

    // MARK: Live streams

    /// Keeps a live stream playing smoothly and close to live.
    private func watchLiveBuffer(_ ahead: Double) {
        guard !waitingForBuffer, let o = owner, o.clockRunning else { aheadSince = 0; return }
        let now = CFAbsoluteTimeGetCurrent()
        // Ran dry (the network stalled): hold the picture until a little has arrived again.
        if ahead < -0.1 {
            waitingForBuffer = true
            bufferStartedAt = o.clock.currentTime().seconds        // carry on from where the clock stopped
            aheadSince = 0
            onMain { $0.stalled() }
            return
        }
        // A pushed stream creeps ahead when the sender's clock runs a little fast (or after a burst):
        // if it stays well ahead, skip forward so the delay doesn't keep growing.
        guard pushed else { return }
        if ahead > 2.0 {
            if aheadSince == 0 { aheadSince = now }
            else if now - aheadSince > 3 {
                aheadSince = 0
                let t = (vIndex >= 0 ? lastVideoPTS : lastAudioPTS) - 0.8
                onMain { $0.jumpClock(to: t) }
            }
        } else { aheadSince = 0 }
    }

    /// A live stream's timestamps jumped (the source restarted, or wrapped): start the clock again from here.
    private func liveDiscontinuity(_ t: Double, last: Double) -> Bool {
        guard live, last >= 0, t < last - 3 || t > last + 10 else { return false }
        resetTiming()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { [weak self] in self?.owner?.flushRenderers(); self?.owner?.stalled(); sem.signal() }
        sem.wait()
        return true
    }

    private func resetTiming() {
        lastVideoPTS = -1; lastAudioPTS = -1
        firstVideoPTS = -1; firstAudioPTS = -1
        bufferStartedAt = -1
        waitingForBuffer = true
        aheadSince = 0
    }

    /// The connection dropped: try again for about 30 seconds (each try waits a little longer).
    private func reconnect() -> Bool {
        onMain { $0.notice("Reconnecting…"); $0.stalled() }
        let started = CFAbsoluteTimeGetCurrent()
        var attempt = 0.0
        while !isCancelled && CFAbsoluteTimeGetCurrent() - started < 30 {
            attempt += 1
            cleanup()
            resetTiming()
            reachedEnd = false; videoFormat = nil; hardwareFrames = false; swrInRate = 0; dropBefore = -1
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { [weak self] in self?.owner?.flushRenderers(); sem.signal() }
            sem.wait()
            if open(quiet: true) { onMain { $0.notice("") }; return true }
            let until = CFAbsoluteTimeGetCurrent() + min(attempt, 5)
            while !isCancelled && CFAbsoluteTimeGetCurrent() < until { usleep(50_000) }
        }
        return false
    }

    // MARK: Open

    private func errorText(_ r: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        av_strerror(r, &buf, buf.count)
        return String(cString: buf)
    }

    private func open(quiet: Bool = false) -> Bool {
        func fail(_ msg: String) { if !quiet { self.fail(msg) } }
        var opts: OpaquePointer?
        if url.hasPrefix("http") {
            av_dict_set(&opts, "user_agent", MediaResolver.browserUA, 0)
            av_dict_set(&opts, "reconnect", "1", 0)
            av_dict_set(&opts, "reconnect_streamed", "1", 0)        // live HTTP streams (radio, MPEG-TS) ride out blips
            av_dict_set(&opts, "reconnect_delay_max", "5", 0)
        }
        switch scheme {
        case "rtsp", "rtsps":
            // TCP first: gets through routers and firewalls and loses nothing; UDP if that's all the camera offers
            av_dict_set(&opts, "rtsp_flags", "prefer_tcp", 0)
        case "udp", "rtp":
            // multicast TV: a roomy receive buffer, and a burst that overflows it only drops packets
            av_dict_set(&opts, "overrun_nonfatal", "1", 0)
            av_dict_set(&opts, "fifo_size", "100000", 0)
            av_dict_set(&opts, "buffer_size", "8388608", 0)
        default: break
        }
        guard let alloc = avformat_alloc_context() else { return false }
        alloc.pointee.interrupt_callback = AVIOInterruptCB(callback: ffInterrupt, opaque: Unmanaged.passUnretained(self).toOpaque())
        var ctx: UnsafeMutablePointer<AVFormatContext>? = alloc
        // a network source that doesn't answer (or sends nothing) within 20 s isn't there
        deadline = network ? CFAbsoluteTimeGetCurrent() + 20 : 0
        defer { deadline = 0 }
        let r = avformat_open_input(&ctx, url, nil, &opts)
        av_dict_free(&opts)
        if debugLog && r < 0 { print("ff open \(url): \(r) \(errorText(r))"); fflush(stdout) }
        guard r >= 0, let ctx else {
            if isCancelled { return false }
            fail(!network ? "Couldn't open this file"
                 : r == reel_err_exit() ? "No answer from \(URL(string: url)?.host ?? "the stream")"
                 : "Couldn't connect: \(errorText(r))")
            return false
        }
        fmt = ctx
        guard avformat_find_stream_info(ctx, nil) >= 0 else {
            fail(network ? "Nothing arrived from the stream" : "Couldn't read this file"); return false
        }

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
        // Over the network with no length: live. (A pushed one arrives at the sender's pace.)
        live = network && dur <= 0
        pushed = live && MediaResolver.streamSchemes.contains(scheme)
        bufferStartedAt = live ? -1 : st0
        let a = alpha, playingAudio = aIndex, f = fps, l = live
        onMain { $0.opened(duration: dur, start: st0, size: size, alpha: a, live: l, fps: f, audio: audioList, playingAudio: playingAudio) }
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
        _ = liveDiscontinuity(t, last: lastVideoPTS)
        // Decoded by VideoToolbox: the frame already is a CVPixelBuffer the display layer can show as-is.
        if f.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue, let raw = f.pointee.data.3 {
            let pb = Unmanaged<CVPixelBuffer>.fromOpaque(UnsafeRawPointer(raw)).takeUnretainedValue()
            if !hardwareFrames { hardwareFrames = true; onMain { $0.decodingOnHardware = true } }
            enqueue(pb, at: t)
            return
        }
        let w = Int(f.pointee.width), h = Int(f.pointee.height)
        guard w > 0, h > 0, let pb = makePixelBuffer(w, h) else { return }
        if debugLog && lastVideoPTS < 0 && dropBefore < 0 { print("ff video frame: \(String(cString: av_get_pix_fmt_name(AVPixelFormat(rawValue: f.pointee.format)))) alpha=\(alpha) codec=\(String(cString: avcodec_get_name(vctx!.pointee.codec_id))) decoder=\(String(cString: vctx!.pointee.codec.pointee.name))"); fflush(stdout) }

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
        if firstVideoPTS < 0 { firstVideoPTS = t }
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
        _ = liveDiscontinuity(t, last: lastAudioPTS)
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
        if firstAudioPTS < 0 { firstAudioPTS = t }
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
