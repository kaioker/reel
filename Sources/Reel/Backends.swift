import AppKit
import AVFoundation
import WebKit

protocol BackendDelegate: AnyObject {
    func backendTick()
    func backendStateChanged()
    func backendDidEnd()
    func backendFailed(_ message: String)
    func backendVideoSize(_ size: CGSize)
    func backendTransparent(_ transparent: Bool)
    func backendAudioOnly()
    func backendNeedsWebFallback()
    /// The audio tracks / captions on offer changed (they're found a moment after loading).
    func backendTracksChanged()
}

protocol PlayerBackend: AnyObject {
    /// false = load the track but stay paused (used on launch)
    var autoplay: Bool { get set }
    var view: NSView { get }
    var delegate: BackendDelegate? { get set }
    var currentTime: Double { get }
    var duration: Double { get }
    var isPlaying: Bool { get }
    var hasVideo: Bool { get }
    func load(_ track: Track)
    func play()
    func pause()
    func seek(to seconds: Double)
    func setVolume(_ v: Float)
    func stop()
    /// Playback speed (1 = normal). Kept across tracks.
    var rate: Float { get set }
    /// One frame forward (+1) or back (-1); pauses.
    func step(frames: Int)
    /// Alternative audio tracks in the file (languages, commentary); empty when there's just one / no choice.
    var audioTrackNames: [String] { get }
    var selectedAudioTrack: Int { get }
    func selectAudioTrack(_ i: Int)
}

extension PlayerBackend {
    var audioTrackNames: [String] { [] }
    var selectedAudioTrack: Int { 0 }
    func selectAudioTrack(_ i: Int) {}
}

// MARK: - AVPlayer (local files, direct URLs, HLS)

final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

final class AVBackend: NSObject, PlayerBackend {
    var autoplay = true
    weak var delegate: BackendDelegate?
    let player = AVPlayer()
    private let layerView = PlayerLayerView()
    var view: NSView { layerView }
    private var timeObs: Any?
    private var itemObs: [NSKeyValueObservation] = []
    private var rateObs: NSKeyValueObservation?
    private var endObs: NSObjectProtocol?
    private(set) var hasVideo = true
    var rate: Float = 1 {
        didSet { player.defaultRate = rate; if player.timeControlStatus != .paused { player.rate = rate } }
    }
    private var audioGroup: AVMediaSelectionGroup?

    override init() {
        super.init()
        layerView.playerLayer.player = player
        player.actionAtItemEnd = .pause
        timeObs = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
            self?.delegate?.backendTick()
        }
        rateObs = player.observe(\.timeControlStatus) { [weak self] _, _ in
            DispatchQueue.main.async { self?.delegate?.backendStateChanged() }
        }
    }

    var currentTime: Double { player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0 }
    var duration: Double {
        guard let d = player.currentItem?.duration.seconds, d.isFinite else { return 0 }
        return d
    }
    var isPlaying: Bool { player.timeControlStatus != .paused }

    func load(_ track: Track) {
        guard let url = track.url else { delegate?.backendFailed("Bad URL"); return }
        loadURL(url)
    }

    /// Transparent videos (HEVC with alpha) show whatever is behind the player layer.
    func setTransparent(_ t: Bool) {
        let c = t ? NSColor.clear.cgColor : NSColor.black.cgColor
        layerView.layer?.backgroundColor = c
        layerView.playerLayer.backgroundColor = c
    }

    func loadURL(_ url: URL, headers: [String: String]? = nil) {
        var opts: [String: Any] = [:]
        if let headers { opts["AVURLAssetHTTPHeaderFieldsKey"] = headers }
        let asset = AVURLAsset(url: url, options: opts)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .spectral        // sped-up / slowed-down speech keeps its pitch
        audioGroup = nil
        Task { @MainActor [weak self] in
            let g = try? await asset.loadMediaSelectionGroup(for: .audible)
            guard let self, self.player.currentItem === item else { return }
            self.audioGroup = (g?.options.count ?? 0) > 1 ? g : nil
            self.delegate?.backendTracksChanged()
        }
        itemObs = [
            item.observe(\.status) { [weak self] item, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if item.status == .failed {
                        self.delegate?.backendFailed(item.error?.localizedDescription ?? "Can't play this file")
                    } else if item.status == .readyToPlay {
                        self.delegate?.backendTick()   // lets a paused start be positioned (no ticks while paused)
                    }
                }
            },
            item.observe(\.presentationSize) { [weak self] item, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let s = item.presentationSize
                    if s.width > 0 && s.height > 0 { self.hasVideo = true; self.delegate?.backendVideoSize(s) }
                }
            },
        ]
        hasVideo = true
        Task { @MainActor [weak self] in
            // Audio-only + alpha-channel detection
            let tracks = try? await asset.loadTracks(withMediaType: .video)
            if let tracks, tracks.isEmpty {
                self?.hasVideo = false
                self?.delegate?.backendAudioOnly()
                return
            }
            if let v = tracks?.first, let decodable = try? await v.load(.isDecodable), !decodable {
                self?.delegate?.backendNeedsWebFallback()
                return
            }
            var alpha = false
            if let v = tracks?.first, let fds = try? await v.load(.formatDescriptions) {
                alpha = fds.contains { fd in
                    let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any]
                    return (ext?[kCMFormatDescriptionExtension_ContainsAlphaChannel as String] as? Bool) == true
                        || CMFormatDescriptionGetMediaSubType(fd) == kCMVideoCodecType_HEVCWithAlpha
                }
            }
            self?.setTransparent(alpha)
            self?.delegate?.backendTransparent(alpha)
        }
        if let endObs { NotificationCenter.default.removeObserver(endObs) }
        endObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.delegate?.backendDidEnd()
        }
        player.replaceCurrentItem(with: item)
        if autoplay { player.play() } else { player.pause() }
    }

    func play() { player.play() }
    func pause() { player.pause() }
    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        delegate?.backendTick()
    }
    func setVolume(_ v: Float) { player.volume = v }
    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
    func step(frames: Int) {
        player.pause()
        player.currentItem?.step(byCount: frames)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.delegate?.backendTick(); self.delegate?.backendStateChanged() }
    }
    var audioTrackNames: [String] { audioGroup?.options.map(Self.name) ?? [] }
    var selectedAudioTrack: Int {
        guard let g = audioGroup, let o = player.currentItem?.currentMediaSelection.selectedMediaOption(in: g) else { return 0 }
        return g.options.firstIndex(of: o) ?? 0
    }
    func selectAudioTrack(_ i: Int) {
        guard let g = audioGroup, i >= 0, i < g.options.count else { return }
        player.currentItem?.select(g.options[i], in: g)
    }
    private static func name(_ o: AVMediaSelectionOption) -> String {
        let lang = o.locale.flatMap { Locale.current.localizedString(forIdentifier: $0.identifier) }
        let n = o.displayName
        return lang != nil && !n.localizedCaseInsensitiveContains(lang!) ? "\(n) (\(lang!))" : n
    }
}

// MARK: - HTML5 <video> in WebKit (WebM and other formats AVFoundation can't open)

final class HTMLVideoBackend: NSObject, PlayerBackend, WKScriptMessageHandler {
    var autoplay = true
    weak var delegate: BackendDelegate?
    private let web: WKWebView
    var view: NSView { web }
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private var playing = false
    private var volume: Float = 1
    let hasVideo = true
    var isPlaying: Bool { playing }
    var rate: Float = 1 { didSet { js("v.playbackRate=\(rate); v.defaultPlaybackRate=\(rate)") } }
    func step(frames: Int) { js("v.pause(); v.currentTime=Math.max(0, v.currentTime + \(Double(frames) / 30))") }

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        cfg.userContentController.add(WeakHandler(self), name: "reel")
        web.setValue(false, forKey: "drawsBackground")
        web.wantsLayer = true
        web.layer?.backgroundColor = NSColor.black.cgColor
    }

    func load(_ track: Track) {
        guard let url = track.url else { delegate?.backendFailed("Bad URL"); return }
        currentTime = 0; duration = track.duration ?? 0; playing = false
        let src = url.absoluteString.replacingOccurrences(of: "\"", with: "%22")
        let html = """
        <!doctype html><html><head><style>html,body{margin:0;height:100%;background:#000;overflow:hidden}
        video{position:absolute;inset:0;width:100%;height:100%;object-fit:contain}</style></head><body>
        <video id="v" src="\(src)" \(autoplay ? "autoplay" : "preload=\"auto\"") playsinline></video>
        <script>
        const v=document.getElementById('v');
        function post(o){ try{ webkit.messageHandlers.reel.postMessage(o) }catch(e){} }
        v.volume=\(volume); v.defaultPlaybackRate=\(rate); v.playbackRate=\(rate);
        v.addEventListener('loadedmetadata',()=>post({type:'size', w:v.videoWidth, h:v.videoHeight}));
        v.addEventListener('ended',()=>post({type:'ended'}));
        v.addEventListener('error',()=>post({type:'error', code:(v.error&&v.error.code)||0}));
        ['play','pause','playing','waiting'].forEach(e=>v.addEventListener(e,()=>post({type:'tick',t:v.currentTime,d:v.duration||0,p:!v.paused})));
        setInterval(()=>post({type:'tick',t:v.currentTime,d:v.duration||0,p:!v.paused}),250);
        </script></body></html>
        """
        if url.isFileURL {
            // WebKit only reads local media from a page loaded via loadFileURL with access granted.
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Reel", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let page = dir.appendingPathComponent("player.html")
            try? html.write(to: page, atomically: true, encoding: .utf8)
            web.loadFileURL(page, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        } else {
            web.loadHTMLString(html, baseURL: url)
        }
    }

    private func js(_ s: String) { web.evaluateJavaScript(s, completionHandler: nil) }
    func play() { js("v.play()") }
    func pause() { js("v.pause()") }
    func seek(to seconds: Double) { currentTime = max(0, seconds); js("v.currentTime=\(max(0, seconds))"); delegate?.backendTick() }
    func setVolume(_ v: Float) { volume = v; js("v.volume=\(v)") }
    func stop() { web.loadHTMLString("", baseURL: nil); playing = false }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "tick":
            currentTime = body["t"] as? Double ?? currentTime
            if let d = body["d"] as? Double, d.isFinite, d > 0 { duration = d }
            let p = body["p"] as? Bool ?? playing
            if p != playing { playing = p; delegate?.backendStateChanged() }
            delegate?.backendTick()
        case "size":
            if let w = body["w"] as? Double, let h = body["h"] as? Double, w > 0, h > 0 { delegate?.backendVideoSize(CGSize(width: w, height: h)) }
            delegate?.backendTransparent(false)
        case "ended": playing = false; delegate?.backendStateChanged(); delegate?.backendDidEnd()
        case "error": delegate?.backendFailed("This file couldn't be decoded (error \(body["code"] ?? 0))")
        default: break
        }
    }
}

// MARK: - YouTube (IFrame API inside a WKWebView, our own controls on top)

private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

final class YouTubeBackend: NSObject, PlayerBackend, WKScriptMessageHandler, WKNavigationDelegate {
    var autoplay = true
    weak var delegate: BackendDelegate?
    private let web: WKWebView
    var view: NSView { web }
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private var state: Int = -1
    private var pageReady = false
    private var pending: [String] = []
    private var volume: Float = 1
    let hasVideo = true
    var rate: Float = 1 { didSet { js("reelRate(\(rate))") } }
    func step(frames: Int) { pause(); seek(to: max(0, currentTime + Double(frames) / 30)) }
    private var hasTrack = false
    /// YouTube's own captions for this video: (language code, name). Found once it starts playing.
    private(set) var captionTracks: [(code: String, name: String)] = []
    private(set) var captionCode: String?
    func setCaptions(_ code: String?) {
        captionCode = code
        js(code.map { "reelCaption('\($0.replacingOccurrences(of: "'", with: ""))')" } ?? "reelCaptionOff()")
    }

    /// YouTube requires a Referer identifying the embedding app (otherwise error 152/153).
    static let origin = "https://reel.player.app"

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.allowsAirPlayForMediaPlayback = true
        cfg.preferences.isElementFullscreenEnabled = false
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        cfg.userContentController.add(WeakHandler(self), name: "reel")
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.wantsLayer = true
        web.layer?.backgroundColor = NSColor.black.cgColor
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        web.loadHTMLString(Self.html, baseURL: URL(string: Self.origin + "/"))
    }

    var isPlaying: Bool { state == 1 || state == 3 }

    private func js(_ s: String) {
        if pageReady { web.evaluateJavaScript(s, completionHandler: nil) } else { pending.append(s) }
    }

    func load(_ track: Track) {
        currentTime = 0; duration = track.duration ?? 0
        hasTrack = true
        captionTracks = []; captionCode = nil
        delegate?.backendTracksChanged()
        let id = track.source.replacingOccurrences(of: "'", with: "")
        js("reelLoad('\(id)', \(autoplay))")
        js("reelVolume(\(Self.ytVolume(volume)))")
        js("reelRate(\(rate))")
    }
    func play() { js("reelPlay()") }
    func pause() { js("reelPause()") }
    func seek(to seconds: Double) {
        currentTime = max(0, seconds)
        js("reelSeek(\(max(0, seconds)))")
        delegate?.backendTick()
    }
    /// YouTube takes whole numbers 0…100, so keep quiet-but-not-muted levels at 1 rather than 0.
    private static func ytVolume(_ v: Float) -> Int { v <= 0 ? 0 : max(1, Int((v * 100).rounded())) }
    func setVolume(_ v: Float) { volume = v; js("reelVolume(\(Self.ytVolume(v)))") }
    func stop() { js("reelStop()") }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            // only for a video it's been asked to play (the page also gets ready while another player is in use)
            if hasTrack { delegate?.backendTransparent(false) }
            pageReady = true
            let q = pending; pending = []
            q.forEach { web.evaluateJavaScript($0, completionHandler: nil) }
        case "tick":
            currentTime = body["t"] as? Double ?? currentTime
            if let d = body["d"] as? Double, d > 0 { duration = d }
            if let s = body["s"] as? Int, s != state { state = s; delegate?.backendStateChanged() }
            delegate?.backendTick()
        case "state":
            state = body["s"] as? Int ?? state
            delegate?.backendStateChanged()
            if state == 0 { delegate?.backendDidEnd() }
        case "error":
            let code = body["code"] as? Int ?? 0
            let msg: String
            switch code {
            case 101, 150: msg = "The owner doesn't allow this video to play outside YouTube"
            case 100: msg = "Video not found or private"
            case 152, 153: msg = "YouTube refused the embedded player (error \(code))"
            default: msg = "YouTube error \(code)"
            }
            delegate?.backendFailed(msg)
        case "captions":
            let list = (body["list"] as? [[String: Any]]) ?? []
            captionTracks = list.compactMap { d in
                guard let code = d["languageCode"] as? String else { return nil }
                return (code, (d["displayName"] as? String) ?? (d["languageName"] as? String) ?? code)
            }
            delegate?.backendTracksChanged()
        case "log":
            NSLog("[yt] %@", "\(body["m"] ?? "")")
        default: break
        }
    }

    static let html = """
    <!doctype html><html><head>
    <meta name="referrer" content="strict-origin-when-cross-origin">
    <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}
    #p,iframe{position:absolute;inset:0;width:100%!important;height:100%!important;border:0}</style>
    </head><body><div id="p"></div>
    <script>
    var player=null, apiReady=false, queued=null, queuedPlay=true, firstPlay=true, wantRate=1, captionsAsked=false, captionsOn=false;
    function post(o){ try{ webkit.messageHandlers.reel.postMessage(o) }catch(e){} }
    function onYouTubeIframeAPIReady(){ apiReady=true; post({type:'ready'}); if(queued){ var q=queued; queued=null; reelLoad(q, queuedPlay);} }
    function make(id, play){
      firstPlay = play;
      player = new YT.Player('p', {width:'100%', height:'100%', videoId:id, host:'https://www.youtube.com',
        playerVars:{autoplay:(play?1:0), controls:0, disablekb:1, fs:0, iv_load_policy:3, rel:0, playsinline:1,
                    modestbranding:1, enablejsapi:1, origin:'\(origin)', widget_referrer:'\(origin)'},
        events:{
          onReady:function(e){ if(firstPlay) e.target.playVideo(); },
          onStateChange:function(e){ post({type:'state', s:e.data});
            if(e.data==1){ if(wantRate!=1 && e.target.getPlaybackRate()!=wantRate) e.target.setPlaybackRate(wantRate);
              if(!captionsAsked){ captionsAsked=true; reelCaptionList(); } } },
          onError:function(e){ post({type:'error', code:e.data}); }
        }});
    }
    function reelLoad(id, play){
      if(play===undefined) play=true;
      if(!apiReady){ queued=id; queuedPlay=play; return; }
      if(!player || !player.loadVideoById){ if(!player) make(id, play); else setTimeout(function(){reelLoad(id, play)},200); return; }
      captionsAsked=false;
      if(play) player.loadVideoById(id); else player.cueVideoById(id);
    }
    function reelRate(r){ wantRate=r; if(player && player.setPlaybackRate) player.setPlaybackRate(r); }
    // Captions: listing them needs the captions module loaded; leave it off again unless captions were on.
    function reelCaptionList(){
      if(!player || !player.loadModule) return;
      player.loadModule('captions');
      setTimeout(function(){
        var l=[]; try{ l=player.getOption('captions','tracklist')||[]; }catch(e){}
        post({type:'captions', list:l.map(function(t){return {languageCode:t.languageCode, displayName:t.displayName, languageName:t.languageName};})});
        if(!captionsOn){ try{ player.unloadModule('captions'); }catch(e){} }
      }, 1500);
    }
    function reelCaption(code){ captionsOn=true; player.loadModule('captions'); setTimeout(function(){ try{ player.setOption('captions','track',{languageCode:code}); }catch(e){} }, 300); }
    function reelCaptionOff(){ captionsOn=false; try{ player.unloadModule('captions'); }catch(e){} }
    function reelPlay(){ player && player.playVideo && player.playVideo(); }
    function reelPause(){ player && player.pauseVideo && player.pauseVideo(); }
    function reelStop(){ player && player.stopVideo && player.stopVideo(); }
    function reelSeek(t){ player && player.seekTo && player.seekTo(t, true); }
    function reelVolume(v){ if(player && player.setVolume){ player.setVolume(v); if(v>0) player.unMute(); } else setTimeout(function(){reelVolume(v)},300); }
    setInterval(function(){
      if(player && player.getCurrentTime){
        post({type:'tick', t:player.getCurrentTime()||0, d:player.getDuration()||0, s:player.getPlayerState()});
      }
    }, 250);
    </script>
    <script src="https://www.youtube.com/iframe_api"></script>
    </body></html>
    """
}
