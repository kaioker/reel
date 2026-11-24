import AppKit

private let minPanelW: CGFloat = 220
private let maxPanelW: CGFloat = 600
private let minHeightWithPanel: CGFloat = 250
private let minVideoW: CGFloat = 96
/// Shape used when there's no picture: nothing loaded, or audio only.
private let noPictureAspect: CGFloat = 16.0 / 9.0
let debugLog = ProcessInfo.processInfo.environment["REEL_DEBUG"] != nil

/// Transparent layer over the video.
/// left click = play/pause · left drag = move the window · double-click = full screen
/// right drag (or ⌃-drag / two-finger-click drag): ←→ scrub, ↑↓ volume · right click = menu
/// two-finger scroll / wheel: adjust without clicking
final class InteractionView: NSView, RightClickHandling {
    enum Gesture { case none, pending, adjustPending, move, scrub, volume }
    enum ScrollAxis { case none, horizontal, vertical }

    var onClick: (() -> Void)?
    /// Height of the title strip at the top (where the window buttons and title sit). A click there only
    /// brings Reel forward — it never plays/pauses.
    var titleStripHeight: CGFloat = 32
    var onDoubleClick: (() -> Void)?
    var onDrop: ((NSPasteboard) -> Bool)?
    var onContextMenu: ((NSEvent) -> Void)?
    var onGestureBegin: ((Gesture) -> Void)?
    var onScrub: ((CGFloat, Bool) -> Void)?    // (fraction across the video 0…1, finished)
    var onVolume: ((CGFloat, Bool) -> Void)?   // (change since drag start, +1 = full height up, finished)
    var onScrollScrub: ((Double) -> Void)?     // + = forward (trackpad points, or wheel notches ×10)
    var onScrollVolume: ((Double, Bool) -> Void)? // (+ = louder, precise trackpad?)
    var onScrollEnded: (() -> Void)?
    lazy var moveWindow: (NSEvent) -> Void = { [weak self] e in self?.window?.performDrag(with: e) }

    private var downEvent: NSEvent?
    private var start = NSPoint.zero
    private(set) var gesture: Gesture = .none
    private var scrollAxis: ScrollAxis = .none
    private var scrollAccum = CGSize.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .URL, .string])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    /// A click plays/pauses (and a drag moves the window) even when Reel isn't the active app.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var isFullscreen: Bool { window?.styleMask.contains(.fullScreen) ?? false }

    // MARK: Left button: click / move window

    override func mouseDown(with e: NSEvent) {
        if e.modifierFlags.contains(.control) { rightMouseDown(with: e); return }
        downEvent = e
        start = convert(e.locationInWindow, from: nil)
        gesture = .pending
        if e.clickCount == 2 { gesture = .none; onDoubleClick?() }
    }

    override func mouseDragged(with e: NSEvent) {
        if gesture == .adjustPending || gesture == .scrub || gesture == .volume { rightMouseDragged(with: e); return }
        guard gesture == .pending else { return }
        let p = convert(e.locationInWindow, from: nil)
        guard hypot(p.x - start.x, p.y - start.y) >= 4 else { return }
        if isFullscreen {
            gesture = .adjustPending; rightMouseDragged(with: e)   // nothing to move in full screen
        } else if let down = downEvent {
            gesture = .move
            moveWindow(down)
        }
    }

    override func mouseUp(with e: NSEvent) {
        if gesture == .adjustPending || gesture == .scrub || gesture == .volume { rightMouseUp(with: e); return }
        if gesture == .pending, e.clickCount == 1, convert(e.locationInWindow, from: nil).y < bounds.height - titleStripHeight { onClick?() }
        gesture = .none
        downEvent = nil
    }

    // MARK: Right button: drag to adjust, click for the menu

    override func rightMouseDown(with e: NSEvent) {
        downEvent = e
        start = convert(e.locationInWindow, from: nil)
        gesture = .adjustPending
    }

    override func rightMouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let dx = p.x - start.x, dy = p.y - start.y
        switch gesture {
        case .adjustPending:
            guard hypot(dx, dy) >= 3 else { return }
            gesture = abs(dx) >= abs(dy) ? .scrub : .volume
            onGestureBegin?(gesture)
            rightMouseDragged(with: e)
        case .scrub: onScrub?(max(0, min(1, p.x / max(1, bounds.width))), false)
        case .volume: onVolume?(dy / max(bounds.height, 200), false)
        default: break
        }
    }

    override func rightMouseUp(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        switch gesture {
        case .adjustPending:   // plain right click → menu
            onContextMenu?(e)
        case .scrub: onScrub?(max(0, min(1, p.x / max(1, bounds.width))), true)
        case .volume: onVolume?((p.y - start.y) / max(bounds.height, 200), true)
        default: break
        }
        gesture = .none
        downEvent = nil
    }

    // Menu is shown on right-button *release* (so right-drag can adjust instead).
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    // Two-finger scroll (trackpad) or mouse wheel. Fingers right = forward, fingers up = louder.
    override func scrollWheel(with e: NSEvent) {
        if !e.momentumPhase.isEmpty { return }       // no coasting: stop where your fingers stop
        let flip: CGFloat = e.isDirectionInvertedFromDevice ? 1 : -1
        let fx = e.scrollingDeltaX * flip            // + = fingers moved right
        let fy = -e.scrollingDeltaY * flip           // + = fingers moved up
        let precise = e.hasPreciseScrollingDeltas
        if e.phase.contains(.began) || e.phase.isEmpty && !precise { scrollAxis = .none; scrollAccum = .zero }
        if scrollAxis == .none {
            scrollAccum.width += fx; scrollAccum.height += fy
            if precise && hypot(scrollAccum.width, scrollAccum.height) < 3 && !e.phase.isEmpty { return }
            scrollAxis = abs(scrollAccum.width) > abs(scrollAccum.height) ? .horizontal : .vertical
        }
        switch scrollAxis {
        case .horizontal: onScrollScrub?(Double(precise ? fx : fx * 10))
        case .vertical: onScrollVolume?(Double(fy), precise)
        case .none: break
        }
        if e.phase.contains(.ended) || e.phase.contains(.cancelled) { scrollAxis = .none; onScrollEnded?() }
        if e.phase.isEmpty && !precise { onScrollEnded?() }
    }

    /// Return false to refuse the drag (nothing addable in it).
    var onDragEnter: ((NSPasteboard) -> Bool)?
    var onDragExit: (() -> Void)?
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        (onDragEnter?(sender.draggingPasteboard) ?? true) ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { onDragExit?() }
    override func draggingEnded(_ sender: NSDraggingInfo) { onDragExit?() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragExit?()
        return onDrop?(sender.draggingPasteboard) ?? false
    }
}

/// While dragging, the video itself becomes the bar: everything past the current
/// position is dimmed (left→right for time, bottom→top for volume) with a readout in the middle.
final class GestureOverlay: NSView {
    enum Axis { case horizontal, vertical }
    var axis: Axis = .horizontal { didSet { needsDisplay = true } }
    var fraction: CGFloat = 0 { didSet { needsDisplay = true } }
    var text: String = "" { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        let f = max(0, min(1, fraction))
        let dim: NSRect, edge: NSRect
        switch axis {
        case .horizontal:
            let x = (b.width * f).rounded()
            dim = NSRect(x: x, y: 0, width: b.width - x, height: b.height)
            edge = NSRect(x: x - 1, y: 0, width: 2, height: b.height)
        case .vertical:
            let y = (b.height * f).rounded()
            dim = NSRect(x: 0, y: y, width: b.width, height: b.height - y)
            edge = NSRect(x: 0, y: y - 1, width: b.width, height: 2)
        }
        NSColor.black.withAlphaComponent(0.45).setFill()
        dim.fill()
        NSColor.white.withAlphaComponent(0.55).setFill()
        edge.fill()

        guard !text.isEmpty else { return }
        let size = max(11, min(24, b.height * 0.16, b.width * 0.09))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let ts = str.size()
        let pill = NSRect(x: b.midX - ts.width / 2 - size * 0.6, y: b.midY - ts.height / 2 - size * 0.25,
                          width: ts.width + size * 1.2, height: ts.height + size * 0.5)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        str.draw(at: NSPoint(x: b.midX - ts.width / 2, y: b.midY - ts.height / 2))
    }

    func show() { animator().alphaValue = 1 }
    func hide() {
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.3; self.animator().alphaValue = 0 }
    }
}

/// Views that handle right-click / right-drag themselves (icon menu, seek, volume).
protocol RightClickHandling: NSView {}

/// Reel's application object. While Reel isn't the active app, AppKit treats a click on its window as a
/// "bring Reel forward" click and holds it back — so a right-click only focused Reel, and the menu needed a
/// second click. Right-button events on the player go straight to it instead: the icon menu (or right-drag
/// seek/volume) works on the first click, and Reel stays in the background.
final class ReelApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        if !isActive, [.rightMouseDown, .rightMouseDragged, .rightMouseUp].contains(event.type),
           let w = event.window as? PlayerWindow {
            w.sendEvent(event)
            return
        }
        super.sendEvent(event)
    }
}

/// The player window. Right-clicks (menu) and right-drags (seek / volume) work even when Reel
/// isn't focused — normally macOS would spend that click just bringing the window forward.
final class PlayerWindow: NSWindow {
    private weak var rightTarget: NSView?

    override func sendEvent(_ event: NSEvent) {
        // Clicking away from a name you're editing just finishes the rename; the click is used up
        // (it doesn't also play/pause the video or start a track).
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type),
           let field = (firstResponder as? NSTextView)?.delegate as? TripleClickField, field.editingName,
           !field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
            makeFirstResponder(contentView)   // ends editing → commits the name
            return
        }
        switch event.type {
        case .rightMouseDown:
            // Same path focused or not: hand it to the nearest view that handles right-clicks.
            if let frameView = contentView?.superview,
               var v = frameView.hitTest(frameView.convert(event.locationInWindow, from: nil)) as NSView? {
                while !(v is RightClickHandling), let up = v.superview { v = up }
                if v is RightClickHandling {
                    rightTarget = v
                    v.rightMouseDown(with: event)
                    return
                }
            }
        case .rightMouseDragged:
            if let t = rightTarget { t.rightMouseDragged(with: event); return }
        case .rightMouseUp:
            if let t = rightTarget { rightTarget = nil; t.rightMouseUp(with: event); return }
        default: break
        }
        super.sendEvent(event)
    }
}

final class RootView: NSView {
    var layoutHandler: (() -> Void)?
    var onMouseMoved: (() -> Void)?
    var onMouseExited: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Not quite clear: macOS sends clicks and drags *through* fully transparent pixels to the
        // window behind, which made drops miss Reel whenever the glass backdrop was showing.
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.012).cgColor
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); layoutHandler?() }
    override func mouseMoved(with event: NSEvent) { onMouseMoved?() }
    override func mouseEntered(with event: NSEvent) { onMouseMoved?() }
    override func mouseExited(with event: NSEvent) { onMouseExited?() }
    override var acceptsFirstResponder: Bool { true }
}

final class PlayerController: NSObject, NSWindowDelegate, BackendDelegate, PlaylistPanelDelegate, NSMenuItemValidation {
    let window: NSWindow
    private let root = RootView()
    private let videoArea = NSView()
    private let interaction = InteractionView()
    private let overlay = GestureOverlay()
    private let waveform = WaveformView()
    private let flash = PlayPauseFlash()
    private let playlistDot = PlaylistDot()
    private let titleOverlay = TitleOverlay()
    let dropHighlight = DropHighlight()
    let toast = Toast()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let emptyHint = NSTextField(labelWithString: "⌘P")
    let panel = PlaylistPanel()

    private(set) var panelOpen = false
    /// Playlist width: flexes while you resize with it open, remembered for next time.
    private var panelW: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "panelWidth")
        return v > 0 ? max(minPanelW, min(maxPanelW, CGFloat(v))) : 300
    }()
    private var fixedVideoW: CGFloat?
    private var restoreFrame: NSRect?
    private var openedFrame: NSRect?
    private var aspect: CGFloat = 16.0 / 9.0

    private lazy var avBackend: AVBackend = { let b = AVBackend(); b.delegate = self; return b }()
    private lazy var ytBackend: YouTubeBackend = { let b = YouTubeBackend(); b.delegate = self; return b }()
    private lazy var htmlBackend: HTMLVideoBackend = { let b = HTMLVideoBackend(); b.delegate = self; return b }()
    /// In-app FFmpeg decoding: transparent WebM and anything macOS's own player can't decode.
    private lazy var ffBackend: FFBackend = { let b = FFBackend(); b.delegate = self; return b }()
    private let videoGlass: NSView = {
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView(); g.cornerRadius = 0; return g
        }
        let v = NSVisualEffectView(); v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active; return v
    }()
    private var backend: PlayerBackend?
    private var current: (playlist: UUID, track: UUID)?
    private var volume: Float = Prefs.volume
    private var muted = ProcessInfo.processInfo.environment["REEL_MUTE"] != nil
    private var volumeAtDragStart: Float = 1
    private var lastScrubSeek = Date.distantPast
    private var chromeVisible = true
    private var hideTimer: Timer?
    private var keyMonitor: Any?
    private var failTimer: DispatchWorkItem?

    var nowPlayingTrackID: UUID? { current?.track }
    var debugCurrentTime: Double { backend?.currentTime ?? -1 }
    var debugIsPlaying: Bool { backend?.isPlaying ?? false }
    func debugHoldFlash() { flash.debugHold() }
    func debugSeek(_ t: Double) { backend?.seek(to: t) }
    var debugInteraction: InteractionView { interaction }
    var debugBackendName: String { backend.map { String(describing: type(of: $0)) } ?? "-" }
    var debugAudio: String { (backend as? FFBackend)?.debugAudioRendering ?? "-" }
    /// What the audio player is actually set to (AVPlayer gain), for REEL_VOLUME_TEST.
    var debugPlayerGain: Float { (backend as? AVBackend)?.player.volume ?? -1 }
    var debugVolumeLevel: Float { volume }
    func debugScrollVolume(_ notches: Double) { scrollVolume(notches, precise: false) }
    var isIdle: Bool { current == nil }
    private var isFullscreen: Bool { window.styleMask.contains(.fullScreen) }

    override init() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 720, height: 405)
        let rect = NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
        window = PlayerWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.minSize = NSSize(width: minVideoW, height: 54)
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.acceptsMouseMovedEvents = true
        window.delegate = self
        window.title = "Reel"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = root

        root.addSubview(videoArea)
        root.addSubview(panel)
        videoArea.wantsLayer = true
        videoArea.layer?.backgroundColor = NSColor.black.cgColor
        videoGlass.isHidden = true
        videoArea.addSubview(videoGlass)
        message.alignment = .center
        message.textColor = NSColor.white.withAlphaComponent(0.6)
        message.font = .systemFont(ofSize: 13, weight: .medium)
        emptyHint.alignment = .center
        emptyHint.textColor = NSColor.white.withAlphaComponent(0.28)
        // Labels sit under the interaction layer so they never block clicks, drags or drops.
        [waveform, message, emptyHint, overlay, flash, interaction, titleOverlay, toast, dropHighlight].forEach(videoArea.addSubview)
        waveform.isHidden = true
        playlistDot.target = self
        playlistDot.action = #selector(togglePlaylist)

        panel.delegate = self
        panel.isHidden = true
        root.layoutHandler = { [weak self] in self?.layoutAll() }
        root.onMouseMoved = { [weak self] in self?.pokeChrome() }
        root.onMouseExited = { [weak self] in self?.scheduleHide(after: 0.4) }

        interaction.onClick = { [weak self] in self?.togglePlay() }
        interaction.onDoubleClick = { [weak self] in self?.window.toggleFullScreen(nil) }
        interaction.onDrop = { [weak self] pb in
            guard let self else { return false }
            self.scheduleAutoClose(after: 2.5)   // pushed back again once the items actually land
            return self.panel.acceptExternal(pb, at: nil, playFirst: true)
        }
        interaction.onDragEnter = { [weak self] pb in
            guard let self, let s = PlaylistPanel.dropSummary(pb) else { return false }
            self.dropHighlight.show(title: s.isPlaylist ? "Drop to import playlist" : "Drop to play", detail: s.detail)
            // Open the playlist so you can carry the drag over and drop it at a particular spot.
            self.openPanelTemporarily()
            return true
        }
        interaction.onDragExit = { [weak self] in
            self?.dropHighlight.hide()
            self?.scheduleAutoClose(after: 1.0)   // carried away without dropping → close again
        }
        interaction.onContextMenu = { [weak self] _ in self?.showContextMenu() }
        interaction.onGestureBegin = { [weak self] g in self?.gestureBegan(g) }
        interaction.onScrub = { [weak self] f, done in self?.scrubTo(fraction: f, finished: done) }
        interaction.onVolume = { [weak self] d, done in self?.volumeDrag(delta: d, finished: done) }
        interaction.onScrollScrub = { [weak self] d in self?.scrollScrub(d) }
        interaction.onScrollVolume = { [weak self] d, precise in self?.scrollVolume(d, precise: precise) }
        interaction.onScrollEnded = { [weak self] in self?.scheduleOverlayHide() }

        setPin(Prefs.alwaysOnTop)
        updateHUDState()

        // Restore the last video-only frame (panel width is never baked in).
        if let saved = UserDefaults.standard.string(forKey: "videoFrame") {
            let r = NSRectFromString(saved)
            if r.width >= minVideoW, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r) }) {
                aspect = r.width / max(1, r.height)
                window.setFrame(r, display: false)
                window.setFrame(place(r.size, from: r), display: false)
            }
        }
        aspect = noPictureAspect          // nothing loaded yet → 21:9 (same area as last time)
        fitFrameToAspect(animate: false)

        refreshBackdrop()
        scheduleHide(after: 1.5)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.handleKey(e) ?? e }
        NotificationCenter.default.addObserver(forName: Library.changed, object: nil, queue: .main) { [weak self] _ in
            self?.updateHUDState()
        }
    }

    /// On launch: start the first item of the playlist you used last (unless something already started).
    // MARK: Resume after an update restart

    private var pendingSeek: Double?

    /// Saved right before an update restart: playlist, track, position, playing or not.
    func saveResumePoint() {
        guard let c = current, c.playlist != transientID, let b = backend else { return }
        UserDefaults.standard.set([
            "playlist": c.playlist.uuidString, "track": c.track.uuidString,
            "time": b.currentTime, "playing": b.isPlaying, "at": Date().timeIntervalSince1970,
        ] as [String: Any], forKey: "resumePoint")
    }

    /// On launch: pick up where an update restart left off (used once, only if recent). True if it did.
    func resumeIfSaved() -> Bool {
        guard let d = UserDefaults.standard.dictionary(forKey: "resumePoint") else { return false }
        UserDefaults.standard.removeObject(forKey: "resumePoint")
        guard let at = d["at"] as? Double, Date().timeIntervalSince1970 - at < 600,
              let pid = (d["playlist"] as? String).flatMap(UUID.init(uuidString:)),
              let tid = (d["track"] as? String).flatMap(UUID.init(uuidString:)),
              Library.shared.playlist(pid)?.tracks.contains(where: { $0.id == tid }) == true else { return false }
        panel.show(playlist: pid)
        let t = d["time"] as? Double ?? 0
        pendingSeek = t > 1 ? t : nil
        play(playlist: pid, track: tid, startPaused: !(d["playing"] as? Bool ?? false))
        return true
    }

    /// On launch: load the first item of the playlist you used last, paused.
    func autoplayLastPlaylist() {
        guard isIdle else { return }
        let id = panel.shownID
        // Loaded and ready, but paused until you press play.
        if let first = Library.shared.playlist(id)?.tracks.first(where: { $0.isPlayableInSequence }) { play(playlist: id, track: first.id, startPaused: true) }
    }

    func showWindow() {
        window.makeKeyAndOrderFront(nil)   // always opens as just the video; ⌘P shows the playlist
    }

    // MARK: Layout

    private func layoutAll() {
        let W = root.bounds.width, H = root.bounds.height
        var vw = W
        if let f = fixedVideoW {
            vw = f
        } else if panelOpen && isFullscreen {
            vw = max(0, W - panelW)
        } else if panelOpen {
            // Video keeps its shape from the window height; the playlist takes whatever is left.
            vw = max(minVideoW, min(W - minPanelW, (H * aspect).rounded()))
            panelW = W - vw
        }
        videoArea.frame = NSRect(x: 0, y: 0, width: vw, height: H)
        panel.frame = NSRect(x: vw, y: 0, width: panelW, height: H)
        panel.isHidden = !(panelOpen || fixedVideoW != nil)

        let b = videoArea.bounds
        backend?.view.frame = b
        videoGlass.frame = b
        interaction.frame = b
        titleOverlay.frame = NSRect(x: 0, y: b.height - 44, width: b.width, height: 44)
        titleOverlay.isHidden = b.height < 120
        overlay.frame = b
        waveform.frame = b
        flash.frame = b
        toast.frame = b
        dropHighlight.frame = b
        placePlaylistDot()
        message.frame = NSRect(x: 12, y: b.height / 2 - 30, width: max(0, b.width - 24), height: 60)
        message.isHidden = message.stringValue.isEmpty || b.width < 180 || b.height < 110
        let hs = max(14, min(b.height * 0.3, b.width * 0.2))
        emptyHint.font = .systemFont(ofSize: hs, weight: .semibold)
        emptyHint.sizeToFit()
        emptyHint.frame.origin = NSPoint(x: (b.width - emptyHint.frame.width) / 2, y: (b.height - emptyHint.frame.height) / 2)
        emptyHint.isHidden = current != nil
    }

    /// Mirror the traffic lights onto the right edge of the title bar (fades along with them).
    /// The title-bar view that spans the whole window width. On some Macs the traffic lights sit in a
    /// smaller group view inside it, so "close.superview" isn't always the full-width bar.
    private var titlebarHost: NSView? {
        guard let close = window.standardWindowButton(.closeButton) else { return nil }
        var v: NSView? = close.superview
        while let cur = v, cur.frame.width < window.frame.width - 1, let up = cur.superview, up !== window.contentView?.superview { v = up }
        return v ?? close.superview
    }

    /// Mirror the close button onto the right edge, measured in whole-window coordinates so it lines
    /// up however macOS nests the buttons (notch laptops, other OS versions).
    private func placePlaylistDot() {
        guard let close = window.standardWindowButton(.closeButton), let host = titlebarHost else { return }
        if playlistDot.superview !== host { host.addSubview(playlistDot) }
        let c = close.convert(close.bounds, to: nil)          // close button in window coordinates
        let W = window.frame.width, H = window.frame.height
        let mirrored = NSRect(x: W - c.maxX, y: c.minY, width: c.width, height: c.height)
        playlistDot.frame = host.convert(mirrored, from: nil)
        playlistDot.isHidden = isFullscreen
        panel.titleRowCenterFromTop = H - c.midY
        interaction.titleStripHeight = max(28, (H - c.midY) * 2)
        panel.titleRowRightInset = c.maxX + 6
        playlistDot.active = window.isKeyWindow
    }
    func windowDidBecomeKey(_ notification: Notification) { playlistDot.active = true }
    func windowDidResignKey(_ notification: Notification) { playlistDot.active = false }
    func windowDidResize(_ notification: Notification) { placePlaylistDot() }

    // MARK: Resizing (QuickTime-style aspect lock, tiny minimum)

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        if isFullscreen { return frameSize }
        if panelOpen {
            // Not picky: height sets the video size (at its aspect), the playlist absorbs the width.
            let s = sender.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1e5, height: 1e5)
            var H = min(frameSize.height, s.height)
            var vw = max(minVideoW, H * aspect)
            var W = min(frameSize.width, s.width)
            if W - vw < minPanelW {               // too narrow for both → the video gives way
                vw = max(minVideoW, W - minPanelW); H = vw / aspect
                W = max(W, vw + minPanelW)
            }
            if H < minHeightWithPanel {           // never shorter than 250 with the playlist open
                H = min(minHeightWithPanel, s.height); vw = H * aspect
                W = max(W, vw + minPanelW)
            }
            if W - vw > maxPanelW { W = vw + maxPanelW }
            return NSSize(width: W.rounded(), height: H.rounded())
        }
        let pw = panelOpen ? panelW : 0
        // Decide which side leads relative to where the drag *started* (not the last step), so a
        // corner drag never flip-flops between two sizes. The window keeps its aspect and the
        // cursor simply drifts off the corner, like QuickTime.
        let cur = (resizeStart ?? sender.frame).size
        let dw = abs(frameSize.width - cur.width), dh = abs(frameSize.height - cur.height)
        var vw = max(minVideoW, frameSize.width - pw)
        var vh: CGFloat
        if dw >= dh {
            vh = vw / aspect
        } else {
            vh = frameSize.height
            vw = max(minVideoW, vh * aspect)
            vh = vw / aspect
        }
        if let s = sender.screen?.visibleFrame {
            if vw + pw > s.width { vw = s.width - pw; vh = vw / aspect }
            if vh > s.height { vh = s.height; vw = vh * aspect }
        }
        return NSSize(width: (vw + pw).rounded(), height: vh.rounded())
    }

    private func animate(to frame: NSRect, duration: TimeInterval = 0.22, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }, completionHandler: { completion?() })
    }

    private var screenFrame: NSRect { (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame }

    /// Positions a new window size relative to the old frame, keeping whichever screen edges the
    /// window is parked against (e.g. bottom-left corner stays bottom-left), defaulting to the
    /// top-left corner, and always keeping the whole window on screen.
    private func place(_ size: NSSize, from f: NSRect) -> NSRect {
        let s = screenFrame
        let eps: CGFloat = 12
        let atLeft = abs(f.minX - s.minX) < eps, atRight = abs(f.maxX - s.maxX) < eps
        let atBottom = abs(f.minY - s.minY) < eps, atTop = abs(f.maxY - s.maxY) < eps
        let w = min(size.width, s.width), h = min(size.height, s.height)
        var x = (atRight && !atLeft) ? f.maxX - w : f.minX
        var y = (atBottom && !atTop) ? f.minY : f.maxY - h
        if atRight && !atLeft { x = s.maxX - w }
        if atBottom && !atTop { y = s.minY }
        if atLeft { x = s.minX }
        if atTop && !atBottom { y = s.maxY - h }
        x = min(max(x, s.minX), s.maxX - w)
        y = min(max(y, s.minY), s.maxY - h)
        return NSRect(x: x, y: y, width: w, height: h).integral
    }

    /// Largest video size with this aspect that fits on screen next to `extraW` of panel.
    private func clampVideo(_ vw: CGFloat, extraW: CGFloat) -> NSSize {
        let s = screenFrame
        var w = max(minVideoW, vw), h = w / aspect
        if w + extraW > s.width { w = s.width - extraW; h = w / aspect }
        if h > s.height { h = s.height; w = h * aspect }
        return NSSize(width: w, height: h)
    }

    /// Reshape the window to the current aspect ratio while keeping the video's on-screen *area*,
    /// so a tiny window stays tiny when a 4K (or portrait) video loads.
    private func fitFrameToAspect(animate anim: Bool = true) {
        guard !isFullscreen, !window.inLiveResize, fixedVideoW == nil else { return }
        let f = window.frame
        let pw = panelOpen ? panelW : 0
        let area = max(minVideoW * minVideoW / aspect, (f.width - pw) * f.height)
        let v = clampVideo((area * aspect).squareRoot(), extraW: pw)
        let target = place(NSSize(width: v.width + pw, height: v.height), from: f)
        if target.equalTo(f) { return }
        if anim { animate(to: target) } else { window.setFrame(target, display: true) }
    }

    func setPanel(open: Bool) {
        guard open != panelOpen, fixedVideoW == nil else { return }
        if isFullscreen {
            panelOpen = open
            updateOpacity()
            root.needsLayout = true
            return
        }
        let f = window.frame
        if open {
            // Keep the video size, but at least 250 px tall so the playlist is usable;
            // only shrink it if video + playlist can't fit on screen.
            let grownW = f.height < minHeightWithPanel ? minHeightWithPanel * aspect : f.width
            let v = clampVideo(grownW, extraW: panelW)
            let target = place(NSSize(width: v.width + panelW, height: v.height), from: f)
            restoreFrame = f
            openedFrame = target
            panelOpen = true
            fixedVideoW = v.width
            updateOpacity()
            root.needsLayout = true
            animate(to: target) { [weak self] in
                self?.fixedVideoW = nil
                self?.root.needsLayout = true
                self?.panel.revealCurrent(animated: false)
            }
        } else {
            func same(_ a: NSRect, _ b: NSRect) -> Bool {
                abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
            }
            var target: NSRect
            if let r = restoreFrame, let o = openedFrame, same(o, f) {
                target = r   // nothing changed while open: go back exactly where we were
            } else if let r = restoreFrame {
                // Back to the size from before the playlist opened (reshaped, same area, if a
                // differently shaped video loaded meanwhile), anchored where the window is now.
                var size = r.size
                if abs(size.width / max(1, size.height) - aspect) > 0.01 {
                    let area = size.width * size.height
                    size = NSSize(width: (area * aspect).squareRoot(), height: (area / aspect).squareRoot())
                }
                target = place(clampVideo(size.width, extraW: 0), from: f)
            } else {
                let v = clampVideo(f.width - panelW, extraW: 0)
                target = place(v, from: f)
            }
            fixedVideoW = target.width
            animate(to: target) { [weak self] in
                guard let self else { return }
                self.panelOpen = false
                self.fixedVideoW = nil
                self.updateOpacity()
                self.restoreFrame = nil
                self.root.needsLayout = true
            }
        }
    }

    /// After you drag-resize, pull the window back fully on screen if it went past an edge.
    private var resizeStart: NSRect?
    func windowWillStartLiveResize(_ notification: Notification) { resizeStart = window.frame }

    func windowDidEndLiveResize(_ notification: Notification) {
        resizeStart = nil
        if panelOpen { UserDefaults.standard.set(Double(panelW), forKey: "panelWidth") }
        let f = window.frame
        if !screenFrame.contains(f.insetBy(dx: 1, dy: 1)) { animate(to: place(f.size, from: f), duration: 0.15) }
    }
    func windowDidExitFullScreen(_ notification: Notification) { fitFrameToAspect() }
    func windowWillClose(_ notification: Notification) { saveState() }

    func saveState() {
        Library.shared.saveNow()
        guard !isFullscreen else { return }
        var f = window.frame
        if panelOpen {
            f.size.width -= panelW
            f.size.height = f.size.width / aspect
            f.origin.y = window.frame.maxY - f.size.height
        }
        UserDefaults.standard.set(NSStringFromRect(f), forKey: "videoFrame")
        UserDefaults.standard.set(panelOpen, forKey: "panelOpen")
    }

    // MARK: Chrome (HUD + title bar fade)

    private func setChrome(_ visible: Bool) {
        guard visible != chromeVisible else { return }
        chromeVisible = visible
        if videoIsTransparent { refreshBackdrop() }
        if debugLog { print("chrome", visible ? "shown" : "hidden"); fflush(stdout) }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = visible ? 0.12 : 0.35
            titleOverlay.animator().alphaValue = visible ? 1 : 0
            (titlebarHost ?? window.standardWindowButton(.closeButton)?.superview)?.animator().alphaValue = visible ? 1 : 0
        }
        if !visible && isFullscreen { NSCursor.setHiddenUntilMouseMoves(true) }
    }

    private func pokeChrome() {
        setChrome(true)
        scheduleHide(after: 1.5)
    }

    /// Controls stay up only while the mouse is moving, or while it rests on the transport bar.
    private func scheduleHide(after t: TimeInterval) {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: t, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.interaction.gesture != .none { self.scheduleHide(after: 0.5); return }
            self.setChrome(false)
        }
    }

    private func showMessage(_ s: String) {
        message.stringValue = s
        root.needsLayout = true
    }

    // MARK: Playback

    private var currentTrack: Track? {
        guard let c = current else { return nil }
        return list(c.playlist)?.tracks.first { $0.id == c.track }
    }

    private var loadToken = 0

    private var nextAutoplay = true

    /// Files opened from Finder / the Dock play from here: not saved, not shown, each plays once.
    private let transientID = UUID()
    private var transient = Playlist(name: "Opened files")
    private func list(_ id: UUID) -> Playlist? { id == transientID ? transient : Library.shared.playlist(id) }

    private func use(_ next: PlayerBackend) {
        next.autoplay = nextAutoplay
        if backend !== next {
            backend?.stop()
            backend?.view.removeFromSuperview()
            backend = next
            videoArea.addSubview(next.view, positioned: .below, relativeTo: waveform)
            root.needsLayout = true
        }
        next.setVolume(muted ? 0 : Loudness.gain(volume))
    }

    func play(playlist pid: UUID, track tid: UUID, startPaused: Bool = false) {
        nextAutoplay = !startPaused
        guard let track = list(pid)?.tracks.first(where: { $0.id == tid }) else { return }
        failTimer?.cancel()
        current = (pid, tid)
        if pid != transientID { Prefs.lastPlaylist = pid.uuidString }   // remembered for autoplay on next launch
        emptyHint.isHidden = true
        loadToken += 1
        fallbackStage = 0
        let token = loadToken
        if debugLog { print("PLAY \(track.displayName) [\(track.kind)] loop=\(track.loop)"); fflush(stdout) }
        showMessage("")
        nativeSize = nil
        audioOnly = false
        setTransparent(false)

        switch track.kind {
        case .youtube:
            use(ytBackend)
            ytBackend.load(track)
            setAspect(16.0 / 9.0)
        case .bilibili:
            use(avBackend)
            avBackend.stop()
            showMessage("Loading…")
            Task { @MainActor in
                let url = await MediaResolver.bilibiliStream(track.source)
                guard token == self.loadToken else { return }
                guard let url else { self.backendFailed("Bilibili didn't return a stream for this video"); return }
                self.showMessage("")
                self.avBackend.loadURL(url, headers: ["User-Agent": MediaResolver.browserUA, "Referer": "https://www.bilibili.com/"])
            }
        case .local where track.isWebM, .remote where track.isWebM:
            guard let url = track.url else { return }
            backend?.stop()
            Task { @MainActor in
                let alpha = await MediaResolver.webmHasAlpha(url)
                guard token == self.loadToken else { return }
                if alpha {
                    // WebKit drops WebM transparency: decode it in-app (libvpx keeps the alpha) — plays at once.
                    self.fallbackStage = 1
                    self.use(self.ffBackend)
                    self.ffBackend.start(url: url)
                    return
                }
                if false, alpha, MediaResolver.findFFmpeg() != nil {
                    // (old path: convert once to HEVC-with-alpha — now only reached via the failure chain)
                    self.use(self.avBackend)
                    self.showMessage("Preparing transparent video…")
                    let movie = await MediaResolver.alphaMovie(for: url) { [weak self] f in
                        DispatchQueue.main.async {
                            guard let self, token == self.loadToken else { return }
                            self.showMessage("Preparing transparent video… \(Int(f * 100))%")
                        }
                    }
                    guard token == self.loadToken else { return }
                    self.showMessage("")
                    if let movie { self.avBackend.loadURL(movie); return }
                }
                self.use(self.htmlBackend)
                self.htmlBackend.load(track)
            }
        default:
            use(avBackend)
            avBackend.load(track)
        }
        titleOverlay.label.stringValue = track.displayName
        window.title = track.displayName
        updateHUDState()
        panel.refreshNowPlaying()
        root.needsLayout = true
    }

    /// Transparent video: swap the black backdrop for Liquid Glass.
    private var videoIsTransparent = false
    private var audioOnly = false
    /// Liquid Glass shows when there's no picture: nothing loaded, audio-only, or a transparent video.
    private var wantsGlass: Bool { current == nil || videoIsTransparent || audioOnly }

    /// The window only goes see-through when glass actually needs the desktop behind it;
    /// otherwise it's opaque black, which resizes cleanly.
    private func updateOpacity() {
        let clear = panelOpen || fixedVideoW != nil || wantsGlass
        window.isOpaque = !clear
        window.backgroundColor = clear ? .clear : .black
    }

    private func refreshBackdrop() {
        let g = wantsGlass
        // Nothing loaded / audio: always glass. Transparent video: glass only while the playlist or the
        // window buttons are showing — otherwise fully see-through.
        let showGlass = current == nil || audioOnly || (videoIsTransparent && (panelOpen || chromeVisible))
        if debugLog { print("backdrop: glass=\(showGlass) transparentVideo=\(videoIsTransparent) chrome=\(chromeVisible) playlist=\(panelOpen)"); fflush(stdout) }
        videoGlass.isHidden = !g
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            videoGlass.animator().alphaValue = showGlass ? 1 : 0
        }
        videoArea.layer?.backgroundColor = g ? NSColor.clear.cgColor : NSColor.black.cgColor
        avBackend.setTransparent(videoIsTransparent || audioOnly)
        waveform.isHidden = !audioOnly
        updateOpacity()
    }

    private func setTransparent(_ t: Bool) {
        videoIsTransparent = t
        refreshBackdrop()
    }

    /// AVFoundation can't decode this picture (e.g. an unusual codec): play it in WebKit instead.
    /// 0 = native player, 1 = tried WebKit, 2 = tried converting with ffmpeg.
    private var fallbackStage = 0

    /// macOS's player (or WebKit) can't decode this: decode it in-app with FFmpeg instead.
    func backendNeedsWebFallback() {
        guard let t = currentTrack, t.kind == .local || t.kind == .remote, fallbackStage == 0, let url = t.url else { return }
        fallbackStage = 1
        if debugLog { print("in-app decoder for \(t.displayName)"); fflush(stdout) }
        use(ffBackend)
        ffBackend.start(url: url)
    }

    func backendAudioOnly() {
        guard let t = currentTrack else { return }
        audioOnly = true
        setAspect(noPictureAspect)
        waveform.title = t.displayName
        waveform.samples = []
        waveform.progress = 0
        refreshBackdrop()
        let token = loadToken
        if let url = t.url {
            Task { @MainActor in
                let s = await Task.detached(priority: .userInitiated) { await WaveformView.load(url) }.value
                if token == self.loadToken { self.waveform.samples = s }
            }
        }
    }

    func backendTransparent(_ transparent: Bool) {
        if debugLog { print("transparent=\(transparent) backend=\(type(of: backend!))"); fflush(stdout) }
        setTransparent(transparent)
    }

    private func setAspect(_ a: CGFloat) {
        guard a.isFinite, a > 0.1, a < 10, abs(a - aspect) > 0.005 else { return }
        aspect = a
        fitFrameToAspect()
    }

    private func neighbors() -> (list: [Track], index: Int)? {
        if let c = current, let p = list(c.playlist), let i = p.tracks.firstIndex(where: { $0.id == c.track }) {
            return (p.tracks, i)
        }
        return nil
    }

    // Struck-through (skipped) tracks are passed over here; clicking one still plays it.
    func nextTrack(auto: Bool = false) {
        if let (list, i) = neighbors() {
            if let n = list[(i + 1)...].first(where: { $0.isPlayableInSequence }) { play(playlist: current!.playlist, track: n.id) }
            else if current!.playlist != transientID, let first = list.first(where: { $0.isPlayableInSequence }) {
                play(playlist: current!.playlist, track: first.id)   // end of the playlist → round to the front
            }
            else if auto { backend?.pause(); updateHUDState() }      // opened files play once, then stop
        } else if let first = panel.tracks.first(where: { $0.isPlayableInSequence }) {
            play(playlist: panel.shownID, track: first.id)
        } else if let c = current, let p = list(c.playlist), let first = p.tracks.first(where: { $0.isPlayableInSequence }) {
            play(playlist: c.playlist, track: first.id)   // current track was deleted
        }
    }

    func prevTrack() {
        if let (list, i) = neighbors() {
            if let p = list[..<i].last(where: { $0.isPlayableInSequence }) { play(playlist: current!.playlist, track: p.id) } else { backend?.seek(to: 0) }
        } else if let last = panel.tracks.last(where: { $0.isPlayableInSequence }) {
            play(playlist: panel.shownID, track: last.id)
        }
    }

    var debugToggleCount = 0
    @objc func togglePlay() {
        debugToggleCount += 1
        guard let b = backend, current != nil else { nextTrack(); return }
        let willPlay = !b.isPlaying
        willPlay ? b.play() : b.pause()
        flash.flash(playing: willPlay)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.updateHUDState() }
    }

    func skip(_ s: Double) {
        guard let b = backend else { return }
        var t = b.currentTime + s
        if b.duration > 0 { t = min(t, max(0, b.duration - 0.25)) }
        b.seek(to: max(0, t))
    }

    @objc func toggleLoop() {
        guard let t = currentTrack else { NSSound.beep(); return }
        panelToggleLoop(track: t.id)
        let on = currentTrack?.loop ?? !t.loop
        toast.show(on ? "Loop on" : "Loop off", symbol: on ? "repeat.1" : "repeat", sticky: false)
    }

    @objc func togglePin() { setPin(!Prefs.alwaysOnTop) }

    private func setPin(_ on: Bool) {
        Prefs.alwaysOnTop = on
        window.level = on ? .floating : .normal
        if on { window.collectionBehavior.insert(.fullScreenAuxiliary) } else { window.collectionBehavior.remove(.fullScreenAuxiliary) }
    }

    @objc func togglePlaylist() {
        panelAutoOpened = false              // you're in charge of it now
        autoCloseWork?.cancel()
        setPanel(open: !panelOpen)
    }

    // MARK: Playlist opened by a drop / paste — shows where things went, then closes again

    private var panelAutoOpened = false
    private var autoCloseWork: DispatchWorkItem?

    private func openPanelTemporarily() {
        guard !panelOpen else { return }      // already open (you opened it): leave it alone
        panelAutoOpened = true
        setPanel(open: true)
    }

    private func scheduleAutoClose(after t: TimeInterval) {
        guard panelAutoOpened else { return }
        autoCloseWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.panelAutoOpened, self.panelOpen else { return }
            let mouse = self.root.convert(self.window.mouseLocationOutsideOfEventStream, from: nil)
            let busy = NSEvent.pressedMouseButtons != 0          // still dragging
                || self.panel.frame.contains(mouse)                // you're working in the playlist
                || self.panel.isBusy                               // links still resolving
                || self.window.attachedSheet != nil                // e.g. the YouTube playlist question
            if busy { self.scheduleAutoClose(after: 0.8); return }
            self.panelAutoOpened = false
            self.setPanel(open: false)
        }
        autoCloseWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: w)
    }

    /// ⇧↑ / ⇧↓: the previous / next playlist, starting its first track (paused if you were paused).
    func switchPlaylist(_ delta: Int) {
        let all = Library.shared.playlists
        guard all.count > 1, let i = all.firstIndex(where: { $0.id == panel.shownID }) else { return }
        let p = all[(i + delta + all.count) % all.count]
        panel.show(playlist: p.id)
        toast.show("“\(p.name)”", symbol: "music.note.list", sticky: false)
        let wasPlaying = backend?.isPlaying ?? false
        if let first = p.tracks.first(where: { $0.isPlayableInSequence }) {
            play(playlist: p.id, track: first.id, startPaused: !wasPlaying)
        }
    }

    private func updateHUDState() {
        panel.setTransport(playing: backend?.isPlaying ?? false, loop: currentTrack?.loop ?? false, hasTrack: current != nil)
        if let t = currentTrack {
            titleOverlay.label.stringValue = t.displayName
            window.title = t.displayName
        }
    }

    // MARK: BackendDelegate

    private var lastLog = 0.0
    func backendTick() {
        guard let b = backend else { return }
        if let s = pendingSeek, b.duration > 0 {
            pendingSeek = nil
            b.seek(to: min(s, max(0, b.duration - 0.5)))
        }
        if audioOnly, b.duration > 0 { waveform.progress = b.currentTime / b.duration }
        if debugLog, Date().timeIntervalSince1970 - lastLog > 1.5 {
            lastLog = Date().timeIntervalSince1970
            print("tick t=\(String(format: "%.1f", b.currentTime)) d=\(String(format: "%.1f", b.duration)) playing=\(b.isPlaying) frame=\(window.frame) panel=\(panelOpen)"); fflush(stdout)
        }
        if let t = currentTrack, b.duration > 0, abs((t.duration ?? 0) - b.duration) > 1.5 {
            let d = b.duration
            Library.shared.mutateTrack(t.id) { $0.duration = d }
        }
    }

    func backendStateChanged() {
        updateHUDState()
    }

    func backendDidEnd() {
        guard let t = currentTrack else { return }
        if debugLog { print("END \(t.displayName) loop=\(t.loop)"); fflush(stdout) }
        if t.loop {
            backend?.seek(to: 0)
            backend?.play()
        } else {
            nextTrack(auto: true)
        }
    }

    func backendFailed(_ msg: String) {
        if debugLog { print("FAILED: \(msg)"); fflush(stdout) }
        guard let c = current else { return }
        // Files and links macOS can't decode: try WebKit, then an ffmpeg conversion, before giving up.
        if let t = currentTrack, t.kind == .local || t.kind == .remote, !t.isWebM || fallbackStage < 2 {
            if fallbackStage == 0 && (backend === avBackend || backend === htmlBackend) {
                backendNeedsWebFallback()
                return
            }
            if fallbackStage <= 1, MediaResolver.findFFmpeg() != nil, let url = t.url {
                fallbackStage = 2
                let token = loadToken
                use(avBackend)
                avBackend.stop()
                showMessage("Converting video…")
                Task { @MainActor in
                    let movie = await MediaResolver.convertedMovie(for: url, keepAlpha: t.isWebM) { [weak self] f in
                        DispatchQueue.main.async {
                            guard let self, token == self.loadToken else { return }
                            self.showMessage("Converting video… \(Int(f * 100))%")
                        }
                    }
                    guard token == self.loadToken else { return }
                    if let movie { self.showMessage(""); self.avBackend.loadURL(movie) }
                    else { self.backendFailed("Couldn't convert it either") }
                }
                return
            }
        }
        showMessage("Can't play this:\n" + msg)
        // Move on after a moment, unless you've already picked something else.
        let w = DispatchWorkItem { [weak self] in
            guard let self, let now = self.current, now.track == c.track else { return }
            if let (list, i) = self.neighbors(), i + 1 < list.count { self.nextTrack(auto: true) }
        }
        failTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }

    /// The video's own resolution in pixels, when the player reports it (YouTube doesn't).
    private var nativeSize: CGSize?

    func backendVideoSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        nativeSize = size
        setAspect(size.width / size.height)
    }

    // MARK: Drag gestures on the video

    /// REEL_GESTURE_TEST: drive synthetic drags through the real event handlers and snapshot the overlay.
    func runGestureTest(snapshotDir: String) {
        let v = interaction
        func ev(_ type: NSEvent.EventType, _ fx: CGFloat, _ fy: CGFloat) -> NSEvent {
            let p = v.convert(NSPoint(x: v.bounds.width * fx, y: v.bounds.height * fy), to: nil)
            return NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func snap(_ name: String) {
            overlay.alphaValue = 1
            if let rep = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) {
                overlay.cacheDisplay(in: overlay.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: snapshotDir + "/" + name + ".png"))
            }
        }
        var moved = 0
        v.moveWindow = { _ in moved += 1 }
        print("before: t=\(String(format: "%.1f", backend?.currentTime ?? -1)) vol=\(volume)")
        // 1. quick drag → moves the window, no seek
        v.mouseDown(with: ev(.leftMouseDown, 0.1, 0.5))
        v.mouseDragged(with: ev(.leftMouseDragged, 0.6, 0.5))
        v.mouseUp(with: ev(.leftMouseUp, 0.6, 0.5))
        print("quick drag: window move calls=\(moved), t=\(String(format: "%.1f", backend?.currentTime ?? -1))")
        // 2. right-drag → scrub
        func rev(_ type: NSEvent.EventType, _ fx: CGFloat, _ fy: CGFloat) -> NSEvent { ev(type, fx, fy) }
        v.rightMouseDown(with: rev(.rightMouseDown, 0.1, 0.5))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            v.rightMouseDragged(with: rev(.rightMouseDragged, 0.4, 0.52))
            v.rightMouseDragged(with: rev(.rightMouseDragged, 0.75, 0.52))
            snap("scrub")
            v.rightMouseUp(with: rev(.rightMouseUp, 0.75, 0.52))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                print("right-drag to 75%: t=\(String(format: "%.1f", self.backend?.currentTime ?? -1)) of \(self.backend?.duration ?? -1)")
                // 3. mouse wheel: 3 notches away from you = louder, shift-wheel = scrub
                self.volume = 0.5; self.muted = false
                for _ in 0..<3 {
                    let c = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!
                    v.scrollWheel(with: NSEvent(cgEvent: c)!)
                }
                print("wheel 3 notches up from 50%: vol=\(self.volume)")
                let before = self.backend?.currentTime ?? 0
                for _ in 0..<2 {
                    let c = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 0, wheel2: -1, wheel3: 0)!
                    v.scrollWheel(with: NSEvent(cgEvent: c)!)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    print("horizontal wheel 2 notches: t \(String(format: "%.1f", before)) -> \(String(format: "%.1f", self.backend?.currentTime ?? -1))")
                    let playing = self.backend?.isPlaying ?? false
                    v.mouseDown(with: ev(.leftMouseDown, 0.5, 0.5)); v.mouseUp(with: ev(.leftMouseUp, 0.5, 0.5))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        print("click toggled play: \(playing) -> \(self.backend?.isPlaying ?? false)"); fflush(stdout)
                        NSApp.terminate(nil)
                    }
                }
            }
        }
        fflush(stdout)
    }

    private func gestureBegan(_ g: InteractionView.Gesture) {
        overlayHideWork?.cancel()
        if g == .volume { volumeAtDragStart = muted ? 0 : volume }
        overlay.show()
    }

    // Scroll / wheel adjusting (relative)
    private var scrollTarget: Double?
    private var overlayHideWork: DispatchWorkItem?

    private func scheduleOverlayHide() {
        overlayHideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.overlay.hide(); self?.scrollTarget = nil; Prefs.volume = self?.volume ?? 1
        }
        overlayHideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: w)
    }

    /// `d` is trackpad points (or wheel notches ×10). Faster for long videos.
    private func scrollScrub(_ d: Double) {
        guard let b = backend, b.duration > 0 else { return }
        let perPoint = max(0.15, b.duration / 2000)
        var t = (scrollTarget ?? b.currentTime) + d * perPoint
        t = max(0, min(t, b.duration - 0.1))
        scrollTarget = t
        if Date().timeIntervalSince(lastScrubSeek) > 0.06 { lastScrubSeek = Date(); b.seek(to: t) }
        overlay.axis = .horizontal
        overlay.fraction = CGFloat(t / b.duration)
        overlay.text = formatTime(t) + " / " + formatTime(b.duration)
        overlay.show()
        scheduleOverlayHide()
        // make sure the final position lands even if the last event was throttled
        let target = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            if self?.scrollTarget == target { b.seek(to: target) }
        }
    }

    private func scrollVolume(_ d: Double, precise: Bool) {
        let step = precise ? Float(d) / 300 : Float(d) * 0.05   // 300 pt swipe = full range; 5% per wheel notch
        let v = max(0, min(1, (muted ? 0 : volume) + step))
        volume = v; muted = false
        backend?.setVolume(Loudness.gain(v))
        overlay.axis = .vertical
        overlay.fraction = CGFloat(v)
        overlay.text = v == 0 ? "Muted" : "\(Int((v * 100).rounded()))%"
        overlay.show()
        scheduleOverlayHide()
    }

    private func scrubTo(fraction f: CGFloat, finished: Bool) {
        guard let b = backend, b.duration > 0 else {
            overlay.axis = .horizontal; overlay.fraction = 0; overlay.text = "Can't seek"
            if finished { overlay.hide() }
            return
        }
        let t = Double(f) * b.duration
        overlay.axis = .horizontal
        overlay.fraction = f
        overlay.text = formatTime(t) + " / " + formatTime(b.duration)
        // Throttle seeks while dragging; always land exactly on release.
        if finished || Date().timeIntervalSince(lastScrubSeek) > 0.08 {
            lastScrubSeek = Date()
            b.seek(to: min(t, max(0, b.duration - 0.1)))
        }
        if finished { overlay.hide() }
    }

    private func volumeDrag(delta: CGFloat, finished: Bool) {
        let v = max(0, min(1, volumeAtDragStart + Float(delta)))
        volume = v
        muted = false
        backend?.setVolume(Loudness.gain(v))
        overlay.axis = .vertical
        overlay.fraction = CGFloat(v)
        overlay.text = v == 0 ? "Muted" : "\(Int((v * 100).rounded()))%"
        if finished { Prefs.volume = v; overlay.hide() }
    }

    func hudToggleMute() {
        muted.toggle()
        backend?.setVolume(muted ? 0 : Loudness.gain(volume))
        toast.show(muted ? "Muted" : "Sound on", symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", sticky: false)
    }

    // MARK: PlaylistPanelDelegate

    func panelPlay(playlist: UUID, track: UUID) { play(playlist: playlist, track: track) }
    func panelPrev() { prevTrack() }
    func panelPlayPause() { togglePlay() }
    func panelNext() { nextTrack() }
    func panelLoopCurrent() { toggleLoop() }
    func panelOpenFiles() { openDocument(nil) }
    func panelNotice(_ text: String, symbol: String, sticky: Bool) { toast.show(text, symbol: symbol, sticky: sticky) }
    func panelWantsToBeSeen() {
        openPanelTemporarily()
        scheduleAutoClose(after: 2.5)
    }

    func panelToggleLoop(track: UUID) {
        if let i = transient.tracks.firstIndex(where: { $0.id == track }) { transient.tracks[i].loop.toggle() }
        Library.shared.mutateTrack(track) { $0.loop.toggle() }
        updateHUDState()
    }

    // MARK: Keyboard

    private func handleKey(_ e: NSEvent) -> NSEvent? {
        guard e.window === window else { return e }
        // Typing in the URL box or renaming something: let the text field have the keys.
        if let tv = window.firstResponder as? NSTextView, tv.isEditable { return e }
        let mods = e.modifierFlags.intersection([.command, .control, .option])
        if !mods.isEmpty { return e }
        return performHotkey(keyCode: e.keyCode, shift: e.modifierFlags.contains(.shift),
                             chars: e.charactersIgnoringModifiers) ? nil : e
    }

    /// Reel's hotkeys. Used when Reel is focused, and by HoverHotkeys when the mouse is over it.
    /// Returns false if the key isn't one of Reel's (so it goes on to wherever it was headed).
    @discardableResult
    func performHotkey(keyCode: UInt16, shift: Bool, chars: String?) -> Bool {
        if shift {
            switch keyCode {
            case 123: prevTrack(); return true          // ⇧←
            case 124: nextTrack(); return true          // ⇧→
            case 126: switchPlaylist(-1); return true   // ⇧↑
            case 125: switchPlaylist(1); return true    // ⇧↓
            default: break
            }
        }
        switch keyCode {
        case 123: skip(-10)                // ←
        case 124: skip(10)                 // →
        case 126: prevTrack()              // ↑
        case 125: nextTrack()              // ↓
        case 49: togglePlay()              // space
        case 53:                           // esc
            if isFullscreen { window.toggleFullScreen(nil) } else { return false }
        default:
            switch chars?.lowercased() {
            case "f": window.toggleFullScreen(nil)
            case "l": toggleLoop()
            case "m": hudToggleMute()
            default: return false
            }
        }
        return true
    }

    /// Is the pointer over the player window (video or playlist) right now?
    func isPointerOverPlayer(_ screenPoint: NSPoint = NSEvent.mouseLocation) -> Bool {
        window.isVisible && !window.isMiniaturized && window.frame.contains(screenPoint)
            && NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0) == window.windowNumber
    }

    // MARK: Menu actions (also reached via the responder chain)

    @objc func openDocument(_ sender: Any?) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.allowedContentTypes = [.audiovisualContent, .folder, .json]
        p.beginSheetModal(for: window) { r in
            if r == .OK { self.panel.add(files: p.urls, at: nil, playFirst: true) }
        }
    }

    /// Opened from Finder / the Dock / "Open With": play straight through once, outside any playlist.
    /// (Exported playlists still import as playlists.)
    func open(files: [URL]) {
        let lists = files.filter { PlaylistFile.readNamed($0) != nil }
        if !lists.isEmpty { panel.add(files: lists, at: nil, playFirst: true) }
        let media = files.filter { !lists.contains($0) }
        let tracks = MediaResolver.tracks(forFiles: media).map { t -> Track in var t = t; t.loop = false; return t }
        guard let first = tracks.first else { return }
        transient = Playlist(id: transientID, name: "Opened files", tracks: tracks)
        play(playlist: transientID, track: first.id)
    }

    @objc func paste(_ sender: Any?) {
        if !panel.acceptExternal(NSPasteboard.general, at: nil, playFirst: isIdle) {
            toast.show("Nothing to paste — copy a link or a file first", symbol: "doc.on.clipboard", sticky: false)
        }
    }
    @objc func newPlaylist(_ sender: Any?) {
        if !panelOpen { setPanel(open: true) }
        panel.newPlaylist()
    }
    @objc func menuTogglePlay(_ sender: Any?) { togglePlay() }
    @objc func menuSkipFwd(_ sender: Any?) { skip(10) }
    @objc func menuSkipBack(_ sender: Any?) { skip(-10) }
    @objc func menuNext(_ sender: Any?) { nextTrack() }
    @objc func menuPrev(_ sender: Any?) { prevTrack() }
    @objc func menuLoop(_ sender: Any?) { toggleLoop() }
    @objc func menuPin(_ sender: Any?) { togglePin() }
    @objc func menuPlaylist(_ sender: Any?) { togglePlaylist() }
    @objc func menuMute(_ sender: Any?) { hudToggleMute() }
    /// ⌘0: the video at its native resolution (1 video pixel = 1 screen pixel), or as large as fits on
    /// the screen if that's smaller. Keeps whichever screen edges/corner the window is parked against.
    @objc func menuActualAspect(_ sender: Any?) {
        guard !isFullscreen else { return }
        let scale = window.backingScaleFactor
        // YouTube doesn't report its resolution; assume 1080p. Nothing/audio: a 1280-wide 16:9-ish frame.
        let px = nativeSize ?? (ytBackendActive ? CGSize(width: 1920, height: 1080) : CGSize(width: 1280 * scale, height: 1280 * scale / aspect))
        let pw = panelOpen ? panelW : 0
        let v = clampVideo(px.width / scale, extraW: pw)          // also caps at the screen size
        let target = place(NSSize(width: v.width + pw, height: v.height), from: window.frame)
        if debugLog { print("fit: native \(Int(px.width))x\(Int(px.height))px @\(scale)x -> \(Int(target.width))x\(Int(target.height))"); fflush(stdout) }
        animate(to: target)
    }

    private var ytBackendActive: Bool { backend === ytBackend }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(menuLoop(_:)): item.state = currentTrack?.loop == true ? .on : .off; return current != nil
        case #selector(menuPin(_:)): item.state = Prefs.alwaysOnTop ? .on : .off
        case #selector(menuPlaylist(_:)): item.title = panelOpen ? "Hide Playlist" : "Show Playlist"
        case #selector(menuMute(_:)): item.state = muted ? .on : .off
        case #selector(menuTogglePlay(_:)): item.title = (backend?.isPlaying == true ? "Pause" : "Play") + "    Space"
        default: break
        }
        return true
    }

    /// Right-click on the video: a row of icons.
    private func showContextMenu() {
        let playing = backend?.isPlaying == true
        let items: [IconMenu.Item] = [
            .init(symbol: playing ? "pause.fill" : "play.fill", tip: playing ? "Pause" : "Play") { [weak self] _ in self?.togglePlay() },
            .init(symbol: "repeat.1", tip: (currentTrack?.loop ?? false) ? "Stop looping this track (L)" : "Loop this track (L)",
                  on: currentTrack?.loop ?? false) { [weak self] _ in self?.toggleLoop() },
            .init(symbol: Prefs.alwaysOnTop ? "pin.fill" : "pin", tip: "Always on top", on: Prefs.alwaysOnTop) { [weak self] _ in self?.togglePin() },
            .init(symbol: "sidebar.right", tip: panelOpen ? "Hide playlist" : "Show playlist", on: panelOpen) { [weak self] _ in self?.togglePlaylist() },
            .init(symbol: "plus", tip: "Add files…") { [weak self] _ in self?.openDocument(nil) },
            .init(symbol: "doc.on.clipboard", tip: "Paste links (⌘V)") { [weak self] _ in self?.paste(nil) },
            .init(symbol: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                  tip: isFullscreen ? "Exit full screen" : "Full screen") { [weak self] _ in self?.window.toggleFullScreen(nil) },
        ]
        IconMenu.shared.show(items, at: NSEvent.mouseLocation)
    }
}
