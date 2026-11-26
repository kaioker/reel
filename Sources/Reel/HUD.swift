import AppKit
import AVFoundation
import AVKit

func symbol(_ name: String, _ size: CGFloat = 14, _ weight: NSFont.Weight = .medium) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: name)?
        .withSymbolConfiguration(.init(pointSize: size, weight: weight))
}

func formatTime(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "0:00" }
    let s = Int(t.rounded(.down))
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

final class IconButton: NSButton {
    var on = false { didSet { contentTintColor = on ? .controlAccentColor : .white } }
    convenience init(_ sym: String, size: CGFloat = 14, tip: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        image = symbol(sym, size)
        isBordered = false
        imagePosition = .imageOnly
        contentTintColor = .white
        toolTip = tip
        self.target = target
        self.action = action
        setButtonType(.momentaryChange)
        focusRingType = .none
    }
    func setSymbol(_ name: String, size: CGFloat = 14) { image = symbol(name, size) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }   // works without focusing Reel first
}

/// Thin QuickTime-style bar used for the scrubber and volume.
final class BarSlider: NSView {
    var value: Double = 0 { didSet { needsDisplay = true } }
    var onChange: ((Double, Bool) -> Void)?   // (value, finished)
    private(set) var dragging = false
    private var hovering = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let h: CGFloat = (hovering || dragging) ? 5 : 3
        let track = NSRect(x: 0, y: bounds.midY - h / 2, width: bounds.width, height: h)
        NSColor.white.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: track, xRadius: h / 2, yRadius: h / 2).fill()
        let fillW = max(0, min(1, value)) * bounds.width
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: track.minY, width: fillW, height: h), xRadius: h / 2, yRadius: h / 2).fill()
        if hovering || dragging {
            let r: CGFloat = 5.5
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: fillW - r, y: bounds.midY - r, width: r * 2, height: r * 2)).fill()
        }
    }
    private func val(_ e: NSEvent) -> Double {
        let p = convert(e.locationInWindow, from: nil)
        return Double(max(0, min(1, p.x / max(1, bounds.width))))
    }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }
    override func mouseDown(with e: NSEvent) { dragging = true; value = val(e); onChange?(value, false) }
    override func mouseDragged(with e: NSEvent) { value = val(e); onChange?(value, false) }
    override func mouseUp(with e: NSEvent) { dragging = false; value = val(e); onChange?(value, true); needsDisplay = true }
    override func scrollWheel(with e: NSEvent) {
        value = max(0, min(1, value + Double(e.scrollingDeltaY) * (e.hasPreciseScrollingDeltas ? 0.004 : 0.04)))
        onChange?(value, true)
    }
}

/// Gradient strip behind the traffic lights + title, like QuickTime.
final class TitleOverlay: NSView {
    let label = NSTextField(labelWithString: "")
    private let grad = CAGradientLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        grad.colors = [NSColor.black.withAlphaComponent(0.55).cgColor, NSColor.black.withAlphaComponent(0).cgColor]
        grad.startPoint = CGPoint(x: 0.5, y: 1); grad.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(grad)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        grad.frame = bounds
        CATransaction.commit()
        label.frame = NSRect(x: 80, y: bounds.height - 22, width: max(0, bounds.width - 160), height: 16)
        label.isHidden = bounds.width < 220
    }
}

/// A fourth "traffic light" on the right of the title bar that toggles the playlist.
/// Drawn to match the native macOS 26 window buttons (measured): 12 pt flat disc in a 14 pt frame,
/// same position mirrored, flat gray when the window isn't key, fine dark glyph on hover, darker while pressed.
final class PlaylistDot: NSButton {
    var hovering = false { didSet { needsDisplay = true } }
    var active = true { didSet { needsDisplay = true } }   // window is key

    // Brightness/saturation matched to the system trio (close ff5c5f, minimize fac800, zoom 34c759)
    private let fillColor = NSColor(srgbRed: 0x2B / 255, green: 0x8C / 255, blue: 0xFF / 255, alpha: 1)
    private let glyphColor = NSColor(srgbRed: 0x00 / 255, green: 0x26 / 255, blue: 0x66 / 255, alpha: 0.85)
    /// Measured from the native buttons in an unfocused window: translucent white, ~14% opacity.
    private let inactiveFill = NSColor(white: 1, alpha: 0.141)

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        toolTip = "Show / hide playlist (⌘P)"
        focusRingType = .none
        refusesFirstResponder = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        // Native discs are 12 pt, flat, centered in the 14 pt button frame.
        let d = min(bounds.width, bounds.height) - 2
        let disc = NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)
        let lit = active || hovering
        var fill = lit ? fillColor : inactiveFill
        if isHighlighted && lit { fill = fill.blended(withFraction: 0.18, of: .black) ?? fill }
        fill.setFill()
        NSBezierPath(ovalIn: disc).fill()

        guard hovering else { return }
        // Fine list glyph (three short rules), weighted like the native ✕ / − / + glyphs.
        let g = NSBezierPath()
        g.lineWidth = 0.9
        g.lineCapStyle = .round
        let w = d * 0.42, x0 = disc.midX - w / 2, gap = d * 0.19
        for i in -1...1 {
            let y = disc.midY + CGFloat(i) * gap
            g.move(to: NSPoint(x: x0, y: y)); g.line(to: NSPoint(x: x0 + w, y: y))
        }
        glyphColor.setStroke()
        g.stroke()
    }
}

/// Audio-only tracks: the file's waveform at 16:9, filling in as it plays.
final class WaveformView: NSView {
    var samples: [Float] = [] { didSet { needsDisplay = true } }
    var progress: Double = 0 { didSet { if abs(progress - oldValue) > 0.001 { needsDisplay = true } } }
    var title: String = "" { didSet { needsDisplay = true } }

    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        let padX = b.width * 0.07
        let area = NSRect(x: padX, y: b.height * 0.22, width: b.width - padX * 2, height: b.height * 0.56)
        let barW: CGFloat = max(2, min(4, area.width / 160))
        let gap: CGFloat = barW * 0.6
        let count = max(1, Int(area.width / (barW + gap)))
        let playedX = area.minX + area.width * CGFloat(max(0, min(1, progress)))
        for i in 0..<count {
            var v: Float = 0.08
            if !samples.isEmpty {
                let lo = i * samples.count / count, hi = max(lo + 1, (i + 1) * samples.count / count)
                v = samples[lo..<min(hi, samples.count)].max() ?? 0
            }
            let h = max(barW, area.height * CGFloat(max(0.04, v)))
            let x = area.minX + CGFloat(i) * (barW + gap)
            let bar = NSRect(x: x, y: area.midY - h / 2, width: barW, height: h)
            (x + barW / 2 <= playedX ? NSColor.white.withAlphaComponent(0.92) : NSColor.white.withAlphaComponent(0.3)).setFill()
            NSBezierPath(roundedRect: bar, xRadius: barW / 2, yRadius: barW / 2).fill()
        }
        guard !title.isEmpty, b.height > 90 else { return }
        let size = max(10, min(15, b.height * 0.05))
        let p = NSMutableParagraphStyle(); p.alignment = .center; p.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .semibold),
                                                    .foregroundColor: NSColor.white.withAlphaComponent(0.85), .paragraphStyle: p]
        (title as NSString).draw(in: NSRect(x: padX, y: b.height * 0.08, width: b.width - padX * 2, height: size * 1.4), withAttributes: attrs)
    }

    /// Peak envelope of a local file (mono, 8 kHz), normalized 0…1.
    static func load(_ url: URL, bins: Int = 600) async -> [Float] {
        guard url.isFileURL else { return pseudo(url.absoluteString, bins: bins) }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let dur = try? await asset.load(.duration).seconds, dur > 0,
              let reader = try? AVAssetReader(asset: asset) else { return pseudo(url.absoluteString, bins: bins) }
        let rate = 8000.0
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1, AVSampleRateKey: rate,
        ])
        reader.add(out)
        guard reader.startReading() else { return pseudo(url.absoluteString, bins: bins) }
        let perBin = max(1, Int(dur * rate) / bins)
        var peaks: [Float] = []; peaks.reserveCapacity(bins + 8)
        var cur: Int16 = 0, n = 0
        while let sb = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sb) {
            var len = 0; var ptr: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr) == noErr, let ptr else { continue }
            ptr.withMemoryRebound(to: Int16.self, capacity: len / 2) { s in
                for i in 0..<(len / 2) {
                    let a = s[i] == Int16.min ? Int16.max : abs(s[i])
                    if a > cur { cur = a }
                    n += 1
                    if n >= perBin { peaks.append(Float(cur)); cur = 0; n = 0 }
                }
            }
        }
        if n > perBin / 2 { peaks.append(Float(cur)) }   // skip a tiny leftover chunk
        let mx = max(1, peaks.max() ?? 1)
        return peaks.map { sqrt($0 / mx) }   // sqrt: quieter parts stay visible
    }

    /// Streams can't be pre-read, so draw a stable, natural-looking shape for them.
    static func pseudo(_ seed: String, bins: Int) -> [Float] {
        var h: UInt64 = 1469598103934665603
        for c in seed.utf8 { h = (h ^ UInt64(c)) &* 1099511628211 }
        var v: Float = 0.5
        return (0..<bins).map { _ in
            h = h &* 6364136223846793005 &+ 1442695040888963407
            v = max(0.15, min(1, v * 0.7 + Float(h >> 40 & 0xFFFF) / 65535 * 0.45))
            return v
        }
    }
}

/// Right-click menu as a row of icons (left → right) on a glass capsule.
/// A non-activating panel, so it works whether or not Reel is focused.
final class IconMenu: NSObject, AVRoutePickerViewDelegate {
    struct Item {
        var symbol: String
        var tip: String
        var on: Bool = false          // shows highlighted (e.g. loop is on)
        var destructive: Bool = false
        /// A thin line between groups of icons.
        var isDivider = false
        /// The system AirPlay button (for this player) in this slot.
        var isAirPlay = false
        var airPlayPlayer: AVPlayer? = nil
        var action: (NSView) -> Void  // receives the clicked icon (for follow-up popups)

        static var divider: Item { Item(symbol: "", tip: "", isDivider: true) { _ in } }
        static func airPlay(_ player: AVPlayer?) -> Item {
            Item(symbol: "airplayvideo", tip: "AirPlay to a TV or speakers", isAirPlay: true, airPlayPlayer: player) { _ in }
        }
    }
    /// The AirPlay list is open: the menu stays until it closes.
    private var airPlayOpen = false

    static let shared = IconMenu()
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private(set) var isShowing = false
    var debugWindowNumber: Int? { panel?.windowNumber }

    /// Tests: open menus here instead of at the pointer (keeps them on the test display).
    static var debugAnchor: NSPoint?

    func show(_ items: [Item], at point: NSPoint) {
        let screenPoint = Self.debugAnchor ?? point
        close()
        let size: CGFloat = 30, pad: CGFloat = 6, gap: CGFloat = 11
        let w = items.reduce(0) { $0 + ($1.isDivider ? gap : size) } + pad * 2, h = size + pad * 2
        let screen = NSScreen.screens.first { $0.frame.contains(screenPoint) }?.visibleFrame ?? NSScreen.main!.visibleFrame
        var origin = NSPoint(x: screenPoint.x - w / 2, y: screenPoint.y + 10)   // just above the pointer
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - w - 4)
        if origin.y + h > screen.maxY { origin.y = screenPoint.y - h - 10 }
        let p = NSPanel(contentRect: NSRect(origin: origin, size: NSSize(width: w, height: h)),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.appearance = NSAppearance(named: .darkAqua)

        let bg: NSView
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView(); g.cornerRadius = h / 2; bg = g
        } else {
            let v = NSVisualEffectView(); v.material = .menu; v.state = .active; v.wantsLayer = true; v.layer?.cornerRadius = h / 2; bg = v
        }
        bg.frame = NSRect(x: 0, y: 0, width: w, height: h)
        let root = NSView(frame: bg.frame)
        root.addSubview(bg)
        var x = pad
        for item in items {
            if item.isDivider {
                let line = NSView(frame: NSRect(x: x + gap / 2 - 0.5, y: pad + 6, width: 1, height: size - 12))
                line.wantsLayer = true
                line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
                root.addSubview(line)
                x += gap
                continue
            }
            if item.isAirPlay {
                let picker = AVRoutePickerView(frame: NSRect(x: x, y: pad, width: size, height: size))
                picker.player = item.airPlayPlayer
                picker.isRoutePickerButtonBordered = false
                picker.setRoutePickerButtonColor(.white, for: .normal)
                picker.toolTip = item.tip
                picker.delegate = self
                root.addSubview(picker)
                x += size
                continue
            }
            let b = MenuIconButton(item: item) { [weak self] sender in
                item.action(sender)
                self?.close()
            }
            b.frame = NSRect(x: x, y: pad, width: size, height: size)
            root.addSubview(b)
            x += size
        }
        p.contentView = root
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
        panel = p
        isShowing = true

        // Dismiss on any click elsewhere (in Reel or another app) or Esc. Like a real menu, a click
        // in Reel that only closes it is used up — it doesn't also play/pause or pick a track.
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] e in
            guard let self, let p = self.panel else { return e }
            if e.type == .keyDown { if e.keyCode == 53 { self.close(); return nil }; return e }
            if e.window === p || self.airPlayOpen { return e }
            self.close()
            return nil
        } as Any)
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            if self?.airPlayOpen != true { self?.close() } }) {
            monitors.append(g)
        }
    }

    func routePickerViewWillBeginPresentingRoutes(_ v: AVRoutePickerView) { airPlayOpen = true }
    func routePickerViewDidEndPresentingRoutes(_ v: AVRoutePickerView) { airPlayOpen = false; close() }

    func close() {
        airPlayOpen = false
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        if let p = panel {
            panel = nil
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
        }
        isShowing = false
    }
}

private final class MenuIconButton: NSButton {
    private let item: IconMenu.Item
    private let handler: (NSView) -> Void
    private var hovering = false { didSet { needsDisplay = true } }

    init(item: IconMenu.Item, handler: @escaping (NSView) -> Void) {
        self.item = item; self.handler = handler
        super.init(frame: .zero)
        isBordered = false
        title = ""
        toolTip = item.tip
        setAccessibilityLabel(item.tip)
        target = self; action = #selector(fire)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }
    @objc private func fire() { handler(self) }

    override func draw(_ dirtyRect: NSRect) {
        if hovering || isHighlighted {
            NSColor.white.withAlphaComponent(isHighlighted ? 0.28 : 0.16).setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5)).fill()
        }
        guard let img = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.tip)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) else { return }
        let color: NSColor = item.destructive ? .systemRed : item.on ? .controlAccentColor : .white
        let tinted = NSImage(size: img.size, flipped: false) { r in
            img.draw(in: r); color.set(); r.fill(using: .sourceAtop); return true
        }
        let s = tinted.size
        tinted.draw(in: NSRect(x: bounds.midX - s.width / 2, y: bounds.midY - s.height / 2, width: s.width, height: s.height))
    }
}

/// Big ▶ / ⏸ that pops in the middle of the video and fades out when playback toggles.
final class PlayPauseFlash: NSView {
    private var fadeTimer: Timer?
    /// Tests: freeze the current frame (at whatever scale the fade reached).
    func debugHold() { fadeTimer?.invalidate() }
    private let disc = CALayer()
    private let icon = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(disc)
        disc.addSublayer(icon)
        disc.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        disc.opacity = 0
        icon.contentsGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func flash(playing: Bool) {
        let d = max(36, min(84, min(bounds.width, bounds.height) * 0.28))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fadeTimer?.invalidate()
        // Reset the scale from the previous flash *before* sizing — setting a layer's frame while it's
        // transformed distorts it (that's what made the disc lopsided and the icon off-center).
        disc.setAffineTransform(.identity)
        disc.bounds = CGRect(x: 0, y: 0, width: d, height: d)
        disc.position = CGPoint(x: bounds.midX, y: bounds.midY)
        disc.cornerRadius = d / 2
        let sym = playing ? "play.fill" : "pause.fill"
        if let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: d * 0.4, weight: .bold)) {
            let tinted = NSImage(size: img.size, flipped: false) { r in
                img.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
            }
            icon.contents = tinted
            icon.contentsScale = window?.backingScaleFactor ?? 2
            let s = tinted.size
            let nudge: CGFloat = playing ? d * 0.04 : 0   // optical centering for the triangle
            icon.bounds = CGRect(origin: .zero, size: s)
            icon.position = CGPoint(x: d / 2 + nudge, y: d / 2)
        }
        CATransaction.commit()

        // Show the disc, then fade it out while it grows a little. Driven by a timer so every
        // step is set explicitly (an implicit fade started in the same tick can be skipped).
        CATransaction.begin(); CATransaction.setDisableActions(true)
        disc.opacity = 1
        disc.setAffineTransform(CGAffineTransform(scaleX: 0.9, y: 0.9))
        CATransaction.commit()
        fadeTimer?.invalidate()
        let start = CACurrentMediaTime()
        let duration = 0.6
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let p = min(1, (CACurrentMediaTime() - start) / duration)
            // Layer properties with implicit animations off, so each frame is exactly what we set.
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.disc.opacity = Float(1 - p * p)                       // ease-in fade
            let sc = 0.9 + 0.4 * p
            self.disc.setAffineTransform(CGAffineTransform(scaleX: sc, y: sc))
            CATransaction.commit()
            if p >= 1 { timer.invalidate() }
        }
        RunLoop.main.add(t, forMode: .common)
        fadeTimer = t
    }
}
