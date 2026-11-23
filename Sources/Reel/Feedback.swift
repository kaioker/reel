import AppKit

/// Shown while something is dragged over the video or the playlist: a dashed accent outline
/// with what will happen ("Drop to play") and what's being dragged ("3 items").
final class DropHighlight: NSView {
    private(set) var title = ""
    private(set) var detail = ""
    /// Video: dim the picture and put the label in the middle. Playlist: keep the rows readable
    /// (so the insertion line shows) and put the label near the bottom.
    var dims = true
    var labelBottomInset: CGFloat = 0 { didSet { needsDisplay = true } }
    private var shown = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(title: String, detail: String) {
        if title != self.title || detail != self.detail { self.title = title; self.detail = detail; needsDisplay = true }
        guard !shown else { return }
        shown = true
        isHidden = false
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; self.animator().alphaValue = 1 }
    }

    func hide() {
        guard shown else { return }
        shown = false
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.18; self.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in if self?.shown == false { self?.isHidden = true } })
    }

    var isShowing: Bool { shown }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        let accent = NSColor.controlAccentColor
        if dims { NSColor.black.withAlphaComponent(0.4).setFill(); b.fill() }
        accent.withAlphaComponent(dims ? 0.16 : 0.1).setFill(); b.fill()

        let inset: CGFloat = min(b.width, b.height) < 120 ? 3 : 6
        let frame = NSBezierPath(roundedRect: b.insetBy(dx: inset, dy: inset), xRadius: 10, yRadius: 10)
        frame.lineWidth = 2.5
        frame.setLineDash([9, 6], count: 2, phase: 0)
        accent.setStroke()
        frame.stroke()

        // Label: icon + title, detail underneath, scaled to the space.
        let small = b.width < 260 || b.height < 140
        let titleSize: CGFloat = dims ? (small ? 13 : max(15, min(22, b.height * 0.07))) : 13
        let titleStr = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: titleSize, weight: .semibold), .foregroundColor: NSColor.white])
        let detailStr = NSAttributedString(string: detail, attributes: [
            .font: NSFont.systemFont(ofSize: max(11, titleSize * 0.72), weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.75)])
        let showIcon = dims && b.height >= 150 && b.width >= 200
        let iconSize = titleSize * 2.2
        let ts = titleStr.size(), ds = detail.isEmpty ? .zero : detailStr.size()
        let maxW = b.width - inset * 2 - 16
        let contentH = (showIcon ? iconSize + 8 : 0) + ts.height + (detail.isEmpty ? 0 : ds.height + 2)
        let pillPadX: CGFloat = 14, pillPadY: CGFloat = 8
        let pillW = min(maxW, max(ts.width, ds.width) + pillPadX * 2)
        let pillH = contentH + pillPadY * 2
        let centerY = dims ? b.midY : labelBottomInset + 14 + pillH / 2
        let pill = NSRect(x: b.midX - pillW / 2, y: centerY - pillH / 2, width: pillW, height: pillH)
        if !dims || !showIcon {
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: pill, xRadius: min(14, pillH / 2), yRadius: min(14, pillH / 2)).fill()
        }
        var y = pill.maxY - pillPadY
        if showIcon, let img = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: iconSize, weight: .regular)) {
            let tinted = NSImage(size: img.size, flipped: false) { r in img.draw(in: r); accent.set(); r.fill(using: .sourceAtop); return true }
            let s = tinted.size
            y -= s.height
            tinted.draw(in: NSRect(x: b.midX - s.width / 2, y: y, width: s.width, height: s.height))
            y -= 8
        }
        y -= ts.height
        titleStr.draw(with: NSRect(x: b.midX - min(ts.width, maxW) / 2, y: y, width: min(ts.width, maxW), height: ts.height),
                      options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
        if !detail.isEmpty {
            y -= ds.height + 2
            detailStr.draw(with: NSRect(x: b.midX - min(ds.width, maxW) / 2, y: y, width: min(ds.width, maxW), height: ds.height),
                           options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
        }
    }
}

/// A short message pill at the bottom of the video: "Added 3 items", "Adding link…", etc.
final class Toast: NSView {
    private let pill = NSView()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?
    private(set) var text = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.68).cgColor
        pill.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        pill.layer?.borderWidth = 1
        icon.contentTintColor = .controlAccentColor
        icon.imageScaling = .scaleProportionallyDown
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        pill.addSubview(icon)
        pill.addSubview(label)
        addSubview(pill)
        pill.alphaValue = 0
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var isShowing: Bool { pill.alphaValue > 0 && !text.isEmpty }

    /// `sticky` messages stay until the next one replaces them (e.g. while links are looked up).
    func show(_ message: String, symbol: String, sticky: Bool = false) {
        text = message
        label.stringValue = message
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        needsLayout = true
        layoutSubtreeIfNeeded()
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; self.pill.animator().alphaValue = 1 }
        guard !sticky else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.4; self.pill.animator().alphaValue = 0 }
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: w)
    }

    override func layout() {
        super.layout()
        let b = bounds
        let small = b.width < 300
        label.font = .systemFont(ofSize: small ? 11 : 13, weight: .semibold)
        let iconW: CGFloat = small ? 14 : 17
        let textW = ceil(label.attributedStringValue.size().width) + 4
        let h: CGFloat = small ? 24 : 30
        let w = min(b.width - 16, 12 + iconW + 6 + textW + 14)
        pill.frame = NSRect(x: ((b.width - w) / 2).rounded(), y: small ? 8 : 16, width: max(0, w), height: h)
        pill.layer?.cornerRadius = h / 2
        icon.frame = NSRect(x: 12, y: (h - iconW) / 2, width: iconW, height: iconW)
        label.frame = NSRect(x: 12 + iconW + 6, y: (h - 17) / 2, width: max(0, w - (12 + iconW + 6) - 12), height: 17)
        pill.isHidden = b.height < 70
    }
}
