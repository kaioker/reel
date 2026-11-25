import AppKit
import UniformTypeIdentifiers

protocol PlaylistPanelDelegate: AnyObject {
    var nowPlayingTrackID: UUID? { get }
    /// The library playlist the playing track belongs to (nil if nothing, or something loose, is playing).
    var nowPlayingPlaylistID: UUID? { get }
    var isIdle: Bool { get }
    func panelPlay(playlist: UUID, track: UUID)
    func panelToggleLoop(track: UUID)
    func panelPrev()
    func panelPlayPause()
    func panelNext()
    func panelLoopCurrent()
    func panelOpenFiles()
    /// A short message on the video ("Added 3 items"). Sticky ones stay until replaced.
    func panelNotice(_ text: String, symbol: String, sticky: Bool)
    /// Open the playlist (something was just added, so show where it went).
    func panelWantsToBeSeen()
    /// What's playing when it isn't in any playlist (dropped on the video, opened from Finder): its title and how many loose items.
    var looseInfo: (title: String, count: Int)? { get }
    func panelAddLoose()
    /// Play a playlist opened without saving (it's in the library, marked unsaved) and show it.
    func panelPlayOpened(_ id: UUID)
    /// Play these now, outside any playlist.
    func panelPlayLoose(_ tracks: [Track])
}

private let reorderType = NSPasteboard.PasteboardType("app.reel.track-rows")

/// Label you can triple-click to rename.
final class TripleClickField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    private var original = ""
    private(set) var editingName = false
    /// Cells in the track table let the table decide (so it can cancel a pending double-click play).
    var handlesRenameClick = true
    /// When set, a click calls this instead (the playlist title: click to see all playlists).
    var onClick: (() -> Void)?

    func configureAsLabel(size: CGFloat, weight: NSFont.Weight) {
        isEditable = false; isSelectable = false; isBordered = false; drawsBackground = false
        font = .systemFont(ofSize: size, weight: weight)
        lineBreakMode = .byTruncatingTail
        cell?.truncatesLastVisibleLine = true
        cell?.usesSingleLineMode = true
        focusRingType = .none
        delegate = self
    }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if let onClick, !editingName { onClick(); return }
        if handlesRenameClick && event.clickCount == 2 && !editingName { beginRename(); return }
        super.mouseDown(with: event)
    }

    func beginRename() {
        guard let window else { return }
        superview?.needsLayout = true
        original = stringValue
        editingName = true
        isEditable = true; isSelectable = true
        drawsBackground = true
        backgroundColor = NSColor.black.withAlphaComponent(0.35)
        window.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }

    private func finish(commit: Bool) {
        guard editingName else { return }
        editingName = false
        let v = stringValue
        isEditable = false; isSelectable = false; drawsBackground = false
        if commit { onCommit?(v) } else { stringValue = original }
        window?.makeFirstResponder(window?.contentView)
    }

    func controlTextDidEndEditing(_ obj: Notification) { finish(commit: true) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            finish(commit: false); return true
        }
        if sel == #selector(NSResponder.insertNewline(_:)) {
            window?.makeFirstResponder(window?.contentView)  // triggers end editing → commit
            return true
        }
        return false
    }
}

final class TrackCell: NSTableCellView {
    let title = TripleClickField()
    let detail = NSTextField(labelWithString: "")
    let badge = NSImageView()
    let fixBtn = NSButton(title: "Fix", target: nil, action: nil)
    let loopBtn = IconButton("repeat.1", size: 12, tip: "Loop this track", target: nil, action: nil)
    var trackID: UUID?
    var playlistID: UUID?

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.configureAsLabel(size: 13, weight: .medium)
        title.textColor = .white
        title.handlesRenameClick = false
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = NSColor.white.withAlphaComponent(0.5)
        detail.lineBreakMode = .byTruncatingTail
        badge.imageScaling = .scaleProportionallyDown
        badge.contentTintColor = .controlAccentColor
        fixBtn.bezelStyle = .push
        fixBtn.controlSize = .small
        fixBtn.font = .systemFont(ofSize: 11, weight: .medium)
        fixBtn.toolTip = "This file isn't on this Mac — choose where it is"
        fixBtn.isHidden = true
        [title, detail, badge, fixBtn].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        badge.frame = NSRect(x: 6, y: (h - 14) / 2, width: 16, height: 14)
        let right: CGFloat = fixBtn.isHidden ? 12 : 58
        fixBtn.frame = NSRect(x: w - 52, y: (h - 22) / 2, width: 46, height: 22)
        title.frame = NSRect(x: 26, y: h / 2 - 1, width: w - 26 - right, height: 18)
        detail.frame = NSRect(x: 27, y: h / 2 - 17, width: w - 27 - right, height: 15)
    }

    /// Double-click only renames when it lands on the title text.
    func titleHit(_ windowPoint: NSPoint) -> Bool {
        title.frame.insetBy(dx: 0, dy: -3).contains(convert(windowPoint, from: nil))
    }
}

final class TrackTable: NSTableView, RightClickHandling {
    var onRightClick: ((Int, NSEvent) -> Void)?
    override func rightMouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onRightClick?(row, event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    /// Drag left the list or finished (the delegate only hears about entering/dropping).
    var onDragExit: (() -> Void)?
    override func draggingExited(_ sender: NSDraggingInfo?) { super.draggingExited(sender); onDragExit?() }
    override func draggingEnded(_ sender: NSDraggingInfo) { super.draggingEnded(sender); onDragExit?() }
    var onPlay: ((Int) -> Void)?
    var onRename: ((Int, NSPoint) -> Void)?
    var onDelete: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if event.clickCount == 2 {
            if row >= 0 { onRename?(row, event.locationInWindow) }   // double-click a title → rename
            return
        }
        let downAt = event.locationInWindow
        super.mouseDown(with: event)   // selection + drag-to-reorder tracking; returns on mouse-up
        // Single click plays — unless it turned into a drag or was a ⌘/⇧ multi-select click.
        let mods = event.modifierFlags.intersection([.command, .shift])
        guard row >= 0, mods.isEmpty, let up = NSApp.currentEvent, up.type == .leftMouseUp,
              hypot(up.locationInWindow.x - downAt.x, up.locationInWindow.y - downAt.y) < 4 else { return }
        onPlay?(row)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { onDelete?(); return }
        if event.keyCode == 36, selectedRow >= 0 { onPlay?(selectedRow); return }
        super.keyDown(with: event)
    }
}

final class PlaylistPanel: NSView, NSTableViewDataSource, NSTableViewDelegate {
    weak var delegate: PlaylistPanelDelegate?
    private(set) var shownID: UUID

    /// Title row: the shown playlist's name and count, cross-faded with "Playlists" and how many.
    let nameField = TripleClickField()
    private let countLabel = NSTextField(labelWithString: "")
    private let listsTitle = TripleClickField()
    private let listsCount = NSTextField(labelWithString: "")
    /// The line under the title row.
    private let headerLine = NSView()
    /// Two panes side by side — all playlists on the left, the shown playlist's tracks on the right — that slide
    /// (click the title, or swipe sideways with two fingers). Both keep the full frame (so their lists always have
    /// rows ready) and slide by layer translation; `listHost` clips them.
    private let listHost = NSView()
    private let playlistsPane = NSView()
    private let tracksPane = NSView()
    private let scroll = PaneScrollView()
    let table = TrackTable()
    private let listsScroll = PaneScrollView()
    let playlistTable = TrackTable()
    /// Which pane is showing (click the title or swipe to switch).
    enum Mode { case tracks, playlists }
    private(set) var mode: Mode = .tracks
    /// 0 = the tracks pane, 1 = all playlists; in between while sliding.
    private var progress: CGFloat = 0
    private let background: NSView = {
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView(); g.cornerRadius = 0; return g
        }
        let v = NSVisualEffectView(); v.material = .sidebar; v.blendingMode = .behindWindow; v.state = .active; return v
    }()
    // Transport row for whatever is playing, with "add media" at the end
    private lazy var prevBtn = IconButton("backward.end.fill", size: 12, tip: "Previous track (↑)", target: self, action: #selector(tPrev))
    private lazy var playBtn = IconButton("play.fill", size: 15, tip: "Play / Pause (Space)", target: self, action: #selector(tPlay))
    private lazy var nextBtn = IconButton("forward.end.fill", size: 12, tip: "Next track (↓)", target: self, action: #selector(tNext))
    private lazy var loopBtn = IconButton("repeat.1", size: 13, tip: "Loop this track (L)", target: self, action: #selector(tLoop))
    private lazy var addBtn = IconButton("plus", size: 15, tip: "Add files… (paste links with ⌘V)", target: self, action: #selector(tAdd))
    private let transportBar = NSView()
    private let spinner = NSProgressIndicator()
    private let emptyHint = NSTextField(wrappingLabelWithString: "Drop files, folders or links here,\npress ⌘V to paste links,\nor click + to choose files.\n\nClick a track to play it.\nDouble-click a title to rename it.")
    private let divider = NSBox()     // the vertical edge against the video
    let dropHighlight: DropHighlight = { let d = DropHighlight(); d.dims = false; return d }()
    /// Shown above the list while something that isn't in a playlist is playing, with an Add button.
    private let looseBar = LooseBar()
    /// Shown above the list for a playlist opened from a .reel file that isn't saved yet.
    private let saveBar = LooseBar(caption: "Opened from a file · not saved", buttonTitle: "Save")
    private var pendingReload = false
    private var resolving = 0
    var isBusy: Bool { resolving > 0 }

    var tracks: [Track] { Library.shared.playlist(shownID)?.tracks ?? [] }
    /// Distance from the top of the window to the traffic lights' center (set by the controller).
    var titleRowCenterFromTop: CGFloat = 16 { didSet { needsLayout = true } }
    /// Space kept free at the right of the title row for the playlist circle.
    var titleRowRightInset: CGFloat = 30 { didSet { needsLayout = true } }

    init() {
        let lib = Library.shared
        if let s = Prefs.lastPlaylist, let id = UUID(uuidString: s), lib.playlist(id) != nil { shownID = id }
        else { shownID = lib.playlists[0].id }
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        addSubview(background)

        for (f, c) in [(nameField, countLabel), (listsTitle, listsCount)] {
            f.configureAsLabel(size: 13, weight: .semibold)
            f.textColor = .white
            f.handlesRenameClick = false
            f.onClick = { [weak self] in self?.toggleMode() }
            c.font = .systemFont(ofSize: 11)
            c.textColor = NSColor.white.withAlphaComponent(0.5)
        }
        listsTitle.stringValue = "Playlists"
        headerLine.wantsLayer = true
        headerLine.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor

        for (t, sc) in [(table, scroll), (playlistTable, listsScroll)] {
            t.addTableColumn(NSTableColumn(identifier: .init("t")))
            t.headerView = nil
            t.rowHeight = 42
            t.intercellSpacing = NSSize(width: 0, height: 2)
            t.backgroundColor = .clear
            t.style = .plain
            t.selectionHighlightStyle = .regular
            t.dataSource = self
            t.delegate = self
            t.focusRingType = .none
            t.registerForDraggedTypes([reorderType, .fileURL, .URL, .string])
            t.setDraggingSourceOperationMask(.move, forLocal: true)
            t.onDragExit = { [weak self] in self?.dropHighlight.hide() }
            sc.documentView = t
            sc.drawsBackground = false
            sc.hasVerticalScroller = true
            sc.autohidesScrollers = true
            sc.scrollerStyle = .overlay
            sc.verticalScroller = TracklessScroller()
            sc.verticalScroller?.knobStyle = .light
            sc.onSwipe = { [weak self] e in self?.trackSwipe(e) ?? false }
        }
        table.allowsMultipleSelection = true
        table.onPlay = { [weak self] row in self?.play(row: row) }
        table.onRename = { [weak self] row, pt in
            // not the second click of a double-click that just opened a playlist
            guard let self, Date().timeIntervalSince(self.lastSwap) > 0.6, let cell = self.table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TrackCell else { return }
            if cell.titleHit(pt) { cell.title.beginRename() }
        }
        table.onDelete = { [weak self] in self?.removeSelected() }
        table.onRightClick = { [weak self] row, e in self?.showContextMenu(row: row, event: e) }
        playlistTable.allowsMultipleSelection = false
        playlistTable.onPlay = { [weak self] row in self?.open(playlistAt: row) }
        playlistTable.onDelete = { [weak self] in
            guard let self, let r = self.playlistTable.selectedRowIndexes.first, r < Library.shared.playlists.count else { return }
            self.deletePlaylist(Library.shared.playlists[r].id)
        }
        playlistTable.onRightClick = { [weak self] row, _ in self?.showPlaylistContextMenu(row: row) }

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        emptyHint.alignment = .center
        emptyHint.font = .systemFont(ofSize: 12)
        emptyHint.textColor = NSColor.white.withAlphaComponent(0.45)

        divider.boxType = .separator

        transportBar.wantsLayer = true
        transportBar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        [prevBtn, playBtn, nextBtn, loopBtn, spinner, addBtn].forEach(transportBar.addSubview)
        setTransport(playing: false, loop: false, hasTrack: false)
        looseBar.isHidden = true
        looseBar.button.target = self; looseBar.button.action = #selector(addLooseClicked)
        saveBar.isHidden = true
        saveBar.button.target = self; saveBar.button.action = #selector(saveClicked)
        listHost.wantsLayer = true
        listHost.layer?.masksToBounds = true
        playlistsPane.addSubview(listsScroll)
        [saveBar, looseBar, scroll, emptyHint].forEach(tracksPane.addSubview)
        for pane in [playlistsPane, tracksPane] { pane.wantsLayer = true; listHost.addSubview(pane) }
        [divider, nameField, countLabel, listsTitle, listsCount, headerLine, listHost, transportBar, dropHighlight].forEach(addSubview)
        registerForDraggedTypes([.fileURL, .URL, .string])

        NotificationCenter.default.addObserver(self, selector: #selector(libraryChanged), name: Library.changed, object: nil)
        // Only *your* scrolling sends live-scroll notifications; programmatic scrolls don't.
        NotificationCenter.default.addObserver(self, selector: #selector(userScrolled), name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        reloadAll()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        background.frame = bounds
        // Short windows (the panel matches the video height) drop the extras progressively.
        let showHeader = H >= 60, showCount = H >= 170, showBar = H >= 90
        divider.frame = NSRect(x: 0, y: 0, width: 1, height: H)
        // Playlist name sits on the same line as the window buttons.
        let cy = H - titleRowCenterFromTop
        let maxNameW = W - 14 - titleRowRightInset - 4
        for (f, c) in [(nameField, countLabel), (listsTitle, listsCount)] {
            let textW = f.editingName ? maxNameW : min(maxNameW, ceil(f.attributedStringValue.size().width) + 6)
            f.frame = NSRect(x: 14, y: cy - 9, width: textW, height: 18)
            c.frame = NSRect(x: 15, y: cy - 28, width: W - 30, height: 15)
        }
        let lineY = showCount ? cy - 36 : cy - 16
        headerLine.frame = NSRect(x: 0, y: lineY, width: W, height: 1)
        headerLine.isHidden = !showHeader
        let top = lineY - 1

        let barH: CGFloat = showBar ? 34 : 0
        transportBar.frame = NSRect(x: 0, y: 0, width: W, height: barH)
        let by: CGFloat = 5, bh: CGFloat = 24
        prevBtn.frame = NSRect(x: 10, y: by, width: 26, height: bh)
        playBtn.frame = NSRect(x: 38, y: by, width: 28, height: bh)
        nextBtn.frame = NSRect(x: 68, y: by, width: 26, height: bh)
        loopBtn.frame = NSRect(x: 102, y: by, width: 26, height: bh)
        addBtn.frame = NSRect(x: W - 36, y: by, width: 26, height: bh)
        spinner.frame = NSRect(x: W - 62, y: by + 4, width: 16, height: 16)

        listHost.frame = NSRect(x: 0, y: barH, width: W, height: max(0, top - barH))
        let pw = listHost.bounds.width, ph = listHost.bounds.height
        playlistsPane.frame = listHost.bounds
        tracksPane.frame = listHost.bounds
        applyProgress()
        listsScroll.frame = NSRect(x: 4, y: 0, width: pw - 8, height: ph)
        // the tracks pane: Save / Add strips on top, then the list
        var paneTop = ph - 6
        for bar in [saveBar, looseBar] {
            if !bar.isHidden && H >= 170 {
                bar.frame = NSRect(x: 8, y: paneTop - 42, width: pw - 16, height: 42)
                paneTop -= 48
            } else {
                bar.frame = .zero
            }
        }
        scroll.frame = NSRect(x: 4, y: 0, width: pw - 8, height: max(0, paneTop + 4))
        table.tableColumns.first?.width = scroll.contentSize.width
        playlistTable.tableColumns.first?.width = listsScroll.contentSize.width
        emptyHint.frame = NSRect(x: 16, y: scroll.frame.midY - 45, width: pw - 32, height: 90)
        emptyHint.isHidden = !tracks.isEmpty || H < 170
        dropHighlight.frame = bounds
        dropHighlight.labelBottomInset = barH
    }

    /// Slides the panes and cross-fades the title row to `progress`.
    private func applyProgress(animated: Bool = false) {
        let p = max(0, min(1, progress))
        let pw = listHost.bounds.width
        let showHeader = bounds.height >= 60, showCount = bounds.height >= 170
        listsTitle.isHidden = !showHeader; nameField.isHidden = !showHeader
        listsCount.isHidden = !showCount; countLabel.isHidden = !showCount
        // the faded-out title stays put but can't be clicked
        nameField.onClick = p < 0.5 ? { [weak self] in self?.toggleMode() } : nil
        listsTitle.onClick = p >= 0.5 ? { [weak self] in self?.toggleMode() } : nil
        // while it moves both panes show; at rest only the one in view does (so clicks reach the right list)
        let moving = animated || (p > 0 && p < 1)
        playlistsPane.isHidden = !moving && p == 0
        tracksPane.isHidden = !moving && p == 1
        let duration = 0.32
        let timing = CAMediaTimingFunction(controlPoints: 0.25, 0.9, 0.3, 1)   // quick start, soft landing
        for (pane, tx) in [(playlistsPane, -(1 - p) * pw), (tracksPane, p * pw)] {
            guard let layer = pane.layer else { continue }
            let from = layer.presentation()?.affineTransform().tx ?? layer.affineTransform().tx
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.setAffineTransform(CGAffineTransform(translationX: tx, y: 0))
            CATransaction.commit()
            if animated {
                let a = CABasicAnimation(keyPath: "transform.translation.x")
                a.fromValue = from; a.toValue = tx; a.duration = duration; a.timingFunction = timing
                layer.add(a, forKey: "slide")
            } else {
                layer.removeAnimation(forKey: "slide")
            }
        }
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = duration
                ctx.timingFunction = timing
                [nameField, countLabel].forEach { $0.animator().alphaValue = 1 - p }
                [listsTitle, listsCount].forEach { $0.animator().alphaValue = p }
            }, completionHandler: { [weak self] in
                guard let self, self.progress == p else { return }   // a newer move took over
                self.playlistsPane.isHidden = p == 0
                self.tracksPane.isHidden = p == 1
            })
        } else {
            [nameField, countLabel].forEach { $0.alphaValue = 1 - p }
            [listsTitle, listsCount].forEach { $0.alphaValue = p }
        }
    }

    // MARK: Two-finger swipe between the panes

    private var swipeStart: CGFloat = 0
    private var swipeTracking = false
    private var fallbackSwipeX: CGFloat = 0

    /// A sideways two-finger swipe anywhere in the playlist: the panes follow your fingers, and let go past
    /// halfway (or with a flick) to switch. Returns true if it took the event (vertical scrolls pass through).
    func trackSwipe(_ e: NSEvent) -> Bool {
        guard e.momentumPhase.isEmpty, !e.phase.isEmpty else { return swipeTracking }   // mouse wheels, momentum: not ours
        let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        if swipeTracking { return true }
        guard (e.phase == .began || e.phase == .changed), abs(dx) > abs(dy) * 1.5, abs(dx) > 0.5 else { return false }
        guard NSEvent.isSwipeTrackingFromScrollEventsEnabled else {
            // "Swipe between pages" is off in System Settings: switch once the swipe has gone far enough.
            fallbackSwipeX = e.phase == .began ? dx : fallbackSwipeX + dx
            let natural = e.isDirectionInvertedFromDevice ? 1.0 : -1.0
            if abs(fallbackSwipeX) > 40 {
                let towardLists = fallbackSwipeX * natural > 0
                if towardLists != (mode == .playlists) { toggleMode() }
                fallbackSwipeX = 0
            }
            return true
        }
        swipeTracking = true
        swipeStart = progress
        let atLists = mode == .playlists
        // gestureAmount > 0: fingers moving right, revealing the pane on the left (all playlists)
        e.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount],
                          dampenAmountThresholdMin: atLists ? -1 : 0, max: atLists ? 0 : 1) { [weak self] amount, phase, complete, _ in
            guard let self else { return }
            self.progress = max(0, min(1, self.swipeStart + amount))
            self.applyProgress()
            if complete {
                self.swipeTracking = false
                let target: Mode = self.progress > 0.5 ? .playlists : .tracks
                self.setMode(target, animated: true)
            } else if phase == .cancelled {
                self.swipeTracking = false
            }
        }
        return true
    }

    /// Tests: freeze the slide part-way (as a swipe would), to see the cross-fade.
    func debugSetProgress(_ p: CGFloat) { progress = p; applyProgress() }

    override func scrollWheel(with event: NSEvent) {
        if trackSwipe(event) { return }
        super.scrollWheel(with: event)
    }

    // MARK: Fix missing files

    @objc private func fixClicked(_ sender: NSButton) {
        guard let cell = sender.superview as? TrackCell, let id = cell.trackID else { return }
        fix(trackID: id)
    }

    /// Point a missing track at the right file. Other missing tracks whose files are in that
    /// same folder get relinked too.
    func fix(trackID: UUID) {
        guard let t = tracks.first(where: { $0.id == trackID }), let window else { return }
        let open = NSOpenPanel()
        open.allowedContentTypes = [.audiovisualContent]
        open.message = "Where is “\(t.displayName)”?" + (t.url.map { "  (was \($0.lastPathComponent.removingPercentEncoding ?? $0.lastPathComponent))" } ?? "")
        open.prompt = "Use This File"
        if let old = t.url?.deletingLastPathComponent(), FileManager.default.fileExists(atPath: old.path) { open.directoryURL = old }
        open.beginSheetModal(for: window) { r in
            guard r == .OK, let picked = open.url else { return }
            self.relink(trackID, to: picked)
            if self.delegate?.isIdle ?? false { self.delegate?.panelPlay(playlist: self.shownID, track: trackID) }
        }
    }

    /// Returns how many *other* missing tracks were found in the same folder and relinked.
    @discardableResult
    func relink(_ trackID: UUID, to picked: URL) -> Int {
        Library.shared.mutateTrack(trackID) { $0.source = picked.absoluteString }
        let dir = picked.deletingLastPathComponent()
        var relinked = 0
        for other in Library.shared.playlists.flatMap(\.tracks) where !other.isAvailable {
            guard let name = other.url?.lastPathComponent.removingPercentEncoding else { continue }
            let candidate = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                Library.shared.mutateTrack(other.id) { $0.source = candidate.absoluteString }
                relinked += 1
            }
        }
        return relinked
    }

    // MARK: Export

    @objc func exportPlaylist() { export(shownID) }

    func export(_ id: UUID) {
        guard let p = Library.shared.playlist(id), let window else { return }
        let save = NSSavePanel()
        save.nameFieldStringValue = p.name.replacingOccurrences(of: "/", with: "-") + ".reel"
        save.allowedContentTypes = [.reelPlaylist]
        save.message = "Drop the exported file on Reel to import it."
        save.beginSheetModal(for: window) { r in
            guard r == .OK, let url = save.url else { return }
            try? self.exportData(p).write(to: url, options: .atomic)
        }
    }

    func exportData(_ p: Playlist) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(PlaylistFile(p))) ?? Data()
    }

    // MARK: Transport row

    @objc private func tPrev() { delegate?.panelPrev() }
    @objc private func tPlay() { delegate?.panelPlayPause() }
    @objc private func tNext() { delegate?.panelNext() }
    @objc private func tLoop() { delegate?.panelLoopCurrent() }
    @objc private func tAdd() { if mode == .playlists { newPlaylist() } else { delegate?.panelOpenFiles() } }

    func setTransport(playing: Bool, loop: Bool, hasTrack: Bool) {
        playBtn.setSymbol(playing ? "pause.fill" : "play.fill", size: 15)
        loopBtn.on = loop
        loopBtn.wantsLayer = true
        loopBtn.layer?.cornerRadius = 7
        loopBtn.layer?.backgroundColor = (loop && hasTrack) ? NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor : nil
        loopBtn.toolTip = loop ? "Looping this track — click to stop (L)" : "Loop this track (L)"
        loopBtn.alphaValue = hasTrack ? (loop ? 1 : 0.6) : 0.3
        loopBtn.isEnabled = hasTrack
    }

    // MARK: Data

    @objc private func libraryChanged() {
        if Library.shared.playlist(shownID) == nil { shownID = Library.shared.playlists[0].id }
        if isEditingSomething { pendingReload = true; return }
        reloadAll()
    }

    private var isEditingSomething: Bool {
        if nameField.editingName { return true }
        for t in [table, playlistTable] {
            for r in 0..<t.numberOfRows {
                if let c = t.view(atColumn: 0, row: r, makeIfNecessary: false) as? TrackCell, c.title.editingName { return true }
            }
        }
        return false
    }

    func reloadAll() {
        func keep(_ t: NSTableView, _ ids: () -> [UUID], _ reload: () -> Void) {
            let before = ids()
            let sel = Set(t.selectedRowIndexes.compactMap { $0 < before.count ? before[$0] : nil })
            reload()
            t.selectRowIndexes(IndexSet(ids().enumerated().filter { sel.contains($0.element) }.map(\.offset)), byExtendingSelection: false)
        }
        reloadHeader()
        keep(table, { tracks.map(\.id) }) { table.reloadData() }
        keep(playlistTable, { Library.shared.playlists.map(\.id) }) { playlistTable.reloadData() }
        emptyHint.isHidden = !tracks.isEmpty || bounds.height < 160
    }

    private func reloadHeader() {
        needsLayout = true
        let n = Library.shared.playlists.count
        listsCount.stringValue = "\(n) playlist\(n == 1 ? "" : "s")"
        let p = Library.shared.playlist(shownID)
        nameField.stringValue = p?.name ?? ""
        nameField.toolTip = "Show all playlists (or swipe right with two fingers)"
        listsTitle.toolTip = "Back to “\(p?.name ?? "the playlist")” (or swipe left with two fingers)"
        addBtn.toolTip = mode == .playlists ? "New playlist" : "Add files… (paste links with ⌘V)"
        countLabel.stringValue = (p?.isUnsaved == true ? "Not saved · " : "") + Self.summary(p?.tracks ?? [])
        refreshLoose()
    }

    static func summary(_ ts: [Track]) -> String {
        let total = ts.compactMap(\.duration).reduce(0, +)
        var s = "\(ts.count) item\(ts.count == 1 ? "" : "s")"
        if total > 0 { s += " · " + formatTime(total) }
        return s
    }

    // MARK: Follow the current track

    /// On until you scroll the current track out of view; back on once you scroll it into view
    /// again or pick a track.
    private(set) var followsCurrent = true

    private var currentRow: Int? {
        guard let id = delegate?.nowPlayingTrackID else { return nil }
        return tracks.firstIndex { $0.id == id }
    }

    private func isRowVisible(_ row: Int) -> Bool {
        let r = table.rect(ofRow: row), vis = scroll.contentView.documentVisibleRect
        return r.intersection(vis).height >= r.height * 0.5
    }

    @objc func userScrolled() {
        if let row = currentRow { followsCurrent = isRowVisible(row) }
    }

    func revealCurrent(animated: Bool = true) {
        guard followsCurrent, let row = currentRow, !isRowVisible(row) else { return }
        let r = table.rect(ofRow: row)
        let clip = scroll.contentView
        let maxY = max(0, table.bounds.height - clip.bounds.height)
        let y = min(maxY, max(0, r.midY - clip.bounds.height / 2))   // center it
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                clip.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
            }
        } else {
            clip.setBoundsOrigin(NSPoint(x: 0, y: y))
        }
        scroll.reflectScrolledClipView(clip)
    }

    func refreshNowPlaying() {
        refreshLoose()
        if let row = currentRow, isRowVisible(row) { followsCurrent = true }
        DispatchQueue.main.async { self.revealCurrent() }
        for r in 0..<table.numberOfRows {
            if let c = table.view(atColumn: 0, row: r, makeIfNecessary: false) as? TrackCell { configure(c, row: r) }
        }
        for r in 0..<playlistTable.numberOfRows {
            if let c = playlistTable.view(atColumn: 0, row: r, makeIfNecessary: false) as? TrackCell { configurePlaylist(c, row: r) }
        }
    }

    /// Shows a playlist's tracks. Doesn't play anything (pick a track for that), and isn't remembered:
    /// reopening the playlist pane shows what's playing.
    func show(playlist id: UUID, animated: Bool = false) {
        if shownID != id { table.deselectAll(nil) }    // a selection doesn't carry across playlists
        shownID = id
        reloadAll()
        followsCurrent = true
        setMode(.tracks, animated: animated)
        DispatchQueue.main.async { self.revealCurrent(animated: false) }
    }

    /// The playlist pane was (re)opened: show the playlist that's playing, at the playing track.
    func showPlaying() {
        show(playlist: delegate?.nowPlayingPlaylistID ?? shownID)
    }

    // MARK: All playlists

    func toggleMode() { setMode(mode == .playlists ? .tracks : .playlists, animated: true) }

    private func setMode(_ m: Mode, animated: Bool) {
        if m != mode { lastSwap = Date() }
        mode = m
        progress = m == .playlists ? 1 : 0
        applyProgress(animated: animated && window != nil)
        reloadHeader()
        if m == .playlists, let i = Library.shared.index(of: shownID) {
            playlistTable.selectRowIndexes([i], byExtendingSelection: false)
            playlistTable.scrollRowToVisible(i)
        }
    }

    private func open(playlistAt row: Int) {
        guard row >= 0, row < Library.shared.playlists.count else { return }
        show(playlist: Library.shared.playlists[row].id, animated: true)
    }

    private var lastSwap = Date.distantPast

    private func configurePlaylist(_ cell: TrackCell, row: Int) {
        let all = Library.shared.playlists
        guard row < all.count else { return }
        let p = all[row]
        cell.trackID = nil
        cell.playlistID = p.id
        if !cell.title.editingName { cell.title.stringValue = p.name }
        cell.title.alphaValue = 1; cell.detail.alphaValue = 1
        cell.fixBtn.isHidden = true
        cell.detail.stringValue = (p.isUnsaved ? "Not saved · " : "") + Self.summary(p.tracks)
        let playing = delegate?.nowPlayingPlaylistID == p.id
        cell.badge.image = playing ? symbol("speaker.wave.2.fill", 11) : nil
        cell.title.textColor = playing ? .controlAccentColor : .white
        cell.title.toolTip = "Click to open · right-click to rename, export or delete · drag to reorder"
        cell.title.onCommit = { name in
            let n = name.trimmingCharacters(in: .whitespaces)
            if !n.isEmpty { Library.shared.mutate(p.id) { $0.name = n } }
        }
        cell.needsLayout = true
    }


    private func showPlaylistContextMenu(row: Int) {
        let all = Library.shared.playlists
        guard row >= 0, row < all.count else { return }
        playlistTable.selectRowIndexes([row], byExtendingSelection: false)
        let p = all[row]
        var items: [IconMenu.Item] = (p.isUnsaved ? [
            .init(symbol: "square.and.arrow.down", tip: "Save to your playlists") { [weak self] _ in self?.save(p.id) },
        ] : []) + [
            .init(symbol: "list.bullet", tip: "Open") { [weak self] _ in self?.show(playlist: p.id, animated: true) },
            .init(symbol: "pencil", tip: "Rename") { [weak self] _ in
                (self?.playlistTable.view(atColumn: 0, row: row, makeIfNecessary: true) as? TrackCell)?.title.beginRename() },
            .init(symbol: "square.and.arrow.up", tip: "Export…") { [weak self] _ in self?.export(p.id) },
        ]
        if let f = Library.shared.fileURL(for: p.id), FileManager.default.fileExists(atPath: f.path) {
            items.append(.init(symbol: "folder", tip: "Show in Finder") { _ in NSWorkspace.shared.activateFileViewerSelecting([f]) })
        }
        if !p.tracks.isEmpty {
            items.append(.init(symbol: "xmark.circle", tip: "Clear (remove every item)") { _ in Library.shared.mutate(p.id) { $0.tracks.removeAll() } })
        }
        items.append(.init(symbol: "trash", tip: "Delete playlist", destructive: true) { [weak self] _ in self?.deletePlaylist(p.id) })
        IconMenu.shared.show(items, at: NSEvent.mouseLocation)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === playlistTable ? Library.shared.playlists.count : tracks.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: .init("cell"), owner: self) as? TrackCell) ?? {
            let c = TrackCell(); c.identifier = .init("cell"); return c
        }()
        if tableView === playlistTable { configurePlaylist(cell, row: row) } else { configure(cell, row: row) }
        return cell
    }

    private func configure(_ cell: TrackCell, row: Int) {
        guard row < tracks.count else { return }
        let t = tracks[row]
        cell.trackID = t.id
        cell.playlistID = nil
        if !cell.title.editingName {
            if t.isSkipped {
                cell.title.attributedStringValue = NSAttributedString(string: t.displayName, attributes: [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: NSColor.white.withAlphaComponent(0.5),
                    .font: cell.title.font ?? NSFont.systemFont(ofSize: 13, weight: .medium),
                    .foregroundColor: delegate?.nowPlayingTrackID == t.id ? NSColor.controlAccentColor : NSColor.white,
                ])
            } else {
                cell.title.stringValue = t.displayName
            }
        }
        let missing = !t.isAvailable
        cell.title.alphaValue = missing ? 0.3 : t.isSkipped ? 0.45 : 1
        cell.detail.alphaValue = missing ? 0.3 : t.isSkipped ? 0.45 : 1
        if missing { cell.detail.stringValue = "Missing · " + (t.url?.lastPathComponent.removingPercentEncoding ?? "file") }
        cell.fixBtn.isHidden = !missing
        cell.fixBtn.target = self
        cell.fixBtn.action = #selector(fixClicked(_:))
        cell.needsLayout = true
        cell.title.toolTip = t.customName != nil ? "\(t.autoTitle)\n\(t.url?.absoluteString ?? "")" : (t.url?.absoluteString ?? "")
        var d = t.subtitle
        if let dur = t.duration, dur > 0 { d += " · " + formatTime(dur) }
        if t.customName != nil { d += " · " + t.autoTitle }
        cell.detail.stringValue = d
        let playing = delegate?.nowPlayingTrackID == t.id
        cell.badge.image = playing ? symbol("speaker.wave.2.fill", 11) : nil
        cell.title.textColor = playing ? .controlAccentColor : .white
        cell.title.onCommit = { name in
            let n = name.trimmingCharacters(in: .whitespaces)
            Library.shared.mutateTrack(t.id) { $0.customName = n.isEmpty || n == $0.autoTitle ? nil : n }
        }
    }

    @objc private func rowLoop(_ sender: NSButton) {
        guard let cell = sender.superview as? TrackCell, let id = cell.trackID else { return }
        delegate?.panelToggleLoop(track: id)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RoundedRowView() }

    private func play(row: Int) {
        guard row >= 0, row < tracks.count else { return }
        if !tracks[row].isAvailable { fix(trackID: tracks[row].id); return }
        followsCurrent = true
        delegate?.panelPlay(playlist: shownID, track: tracks[row].id)
    }

    private func removeSelected() {
        let ids = Set(table.selectedRowIndexes.compactMap { $0 < tracks.count ? tracks[$0].id : nil })
        guard !ids.isEmpty else { return }
        Library.shared.mutate(shownID) { $0.tracks.removeAll { ids.contains($0.id) } }
    }

    // MARK: Right-click (icon row)

    func showContextMenu(row: Int, event: NSEvent) {
        guard row >= 0, row < tracks.count else { return }
        if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes([row], byExtendingSelection: false) }
        let t = tracks[row], pid = shownID
        let many = table.selectedRowIndexes.count
        var items: [IconMenu.Item] = [
            .init(symbol: "play.fill", tip: "Play") { [weak self] _ in self?.delegate?.panelPlay(playlist: pid, track: t.id) },
            .init(symbol: "text.line.first.and.arrowtriangle.forward", tip: many > 1 ? "Play these next" : "Play next") { [weak self] _ in
                self?.playNext() },
            .init(symbol: "pencil", tip: "Rename") { [weak self] _ in self?.beginRename(trackID: t.id) },
        ]
        if t.customName != nil {
            items.append(.init(symbol: "arrow.uturn.backward", tip: "Reset name to “\(t.autoTitle)”") { _ in
                Library.shared.mutateTrack(t.id) { $0.customName = nil } })
        }
        let picked = table.selectedRowIndexes.compactMap { $0 < tracks.count ? tracks[$0] : nil }
        let strike = !t.isSkipped
        items.append(.init(symbol: "strikethrough", tip: strike ? "Skip (strike through) — stays in the playlist, click to play it anyway" : "Stop skipping", on: t.isSkipped) { _ in
            for x in picked { Library.shared.mutateTrack(x.id) { $0.skip = strike ? true : nil } } })
        if t.kind == .local {
            items.append(.init(symbol: "folder", tip: "Show in Finder") { _ in if let u = t.url { NSWorkspace.shared.activateFileViewerSelecting([u]) } })
        } else {
            items.append(.init(symbol: "link", tip: "Copy link") { _ in
                guard let u = t.url else { return }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u.absoluteString, forType: .string) })
        }
        let others = Library.shared.playlists.filter { $0.id != pid }
        if !others.isEmpty {
            items.append(.init(symbol: "rectangle.stack.badge.plus", tip: "Copy to another playlist") { [weak self] sender in
                self?.showCopyToMenu(from: sender) })
        }
        items.append(.init(symbol: "trash", tip: many > 1 ? "Remove \(many) items" : "Remove", destructive: true) { [weak self] _ in
            self?.removeSelected() })
        IconMenu.shared.show(items, at: NSEvent.mouseLocation)
    }

    /// Moves the selected tracks to right after the one playing (copies them across if it's
    /// in another playlist). With nothing playing, they go to the top.
    func playNext() {
        let picked = table.selectedRowIndexes.compactMap { $0 < tracks.count ? tracks[$0] : nil }
        let currentID = delegate?.nowPlayingTrackID
        let moving = picked.filter { $0.id != currentID }
        guard !moving.isEmpty else { return }
        let ids = Set(moving.map(\.id))
        let target = currentID.flatMap { id in Library.shared.playlists.first { $0.tracks.contains { $0.id == id } }?.id } ?? shownID
        if target == shownID {
            Library.shared.mutate(target) { p in
                p.tracks.removeAll { ids.contains($0.id) }
                let at = currentID.flatMap { id in p.tracks.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
                p.tracks.insert(contentsOf: moving, at: at)
            }
        } else {
            Library.shared.mutate(target) { p in
                let at = currentID.flatMap { id in p.tracks.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
                p.tracks.insert(contentsOf: moving.map { var c = $0; c.id = UUID(); return c }, at: at)
            }
        }
    }

    private func beginRename(trackID: UUID) {
        guard let row = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        table.scrollRowToVisible(row)
        (table.view(atColumn: 0, row: row, makeIfNecessary: true) as? TrackCell)?.title.beginRename()
    }

    /// Playlist names have to be words, so this one small choice is a normal menu.
    private func showCopyToMenu(from sender: NSView) {
        let picked = table.selectedRowIndexes.compactMap { $0 < tracks.count ? tracks[$0] : nil }
        let m = NSMenu()
        for p in Library.shared.playlists where p.id != shownID {
            let i = NSMenuItem(title: p.name, action: #selector(copyToPlaylist(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = (p.id, picked)
            m.addItem(i)
        }
        let at = NSEvent.mouseLocation
        DispatchQueue.main.async { m.popUp(positioning: nil, at: at, in: nil) }
    }
    @objc private func copyToPlaylist(_ s: NSMenuItem) {
        guard let (dest, picked) = s.representedObject as? (UUID, [Track]) else { return }
        Library.shared.mutate(dest) { p in p.tracks += picked.map { var t = $0; t.id = UUID(); return t } }
    }

    // MARK: Playlists

    /// A new playlist: shown in the playlists list with its name ready to type.
    @objc func newPlaylist() {
        let p = Library.shared.addPlaylist(named: Library.shared.nextPlaylistName())
        shownID = p.id
        reloadAll()
        setMode(.playlists, animated: true)
        guard let row = Library.shared.index(of: p.id) else { return }
        playlistTable.selectRowIndexes([row], byExtendingSelection: false)
        playlistTable.scrollRowToVisible(row)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            (self.playlistTable.view(atColumn: 0, row: row, makeIfNecessary: true) as? TrackCell)?.title.beginRename()
        }
    }
    private func deletePlaylist(_ id: UUID) {
        guard let p = Library.shared.playlist(id) else { return }
        let a = NSAlert()
        a.messageText = "Delete “\(p.name)”?"
        a.informativeText = p.tracks.isEmpty ? "" : "Its \(p.tracks.count) items will be removed. Files on disk are not touched."
        a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
        a.buttons[0].hasDestructiveAction = true
        guard let w = window else { return }
        a.beginSheetModal(for: w) { r in
            guard r == .alertFirstButtonReturn else { return }
            Library.shared.removePlaylist(p.id)
            if self.shownID == p.id { self.shownID = Library.shared.playlists[0].id }
        }
    }

    // MARK: Adding

    /// Adds resolved items to the shown playlist; autoplays the first one if nothing is playing.
    /// A YouTube *playlist* link first asks what to do with it (see `askAboutPlaylist`).
    func add(text: String, at index: Int?, playFirst: Bool = false) {
        let ytLists = MediaResolver.youtubePlaylistLinks(in: text)
        guard !ytLists.isEmpty else { addResolved(text: text, into: shownID, at: index, playFirst: playFirst); return }
        askAboutPlaylist(.youtube(text: text, links: ytLists), at: index, onVideo: false)
    }

    /// A playlist arriving by drop, paste or + : a .reel file, or a YouTube playlist link.
    enum IncomingPlaylist {
        case files([URL])
        case youtube(text: String, links: [(link: String, video: String?, list: String)])
    }

    /// Asks what to do with a playlist that was dropped / pasted / chosen. `onVideo`: it was dropped on the video
    /// (so whatever you pick also starts playing), rather than on the playlist (where it plays only if nothing is).
    func askAboutPlaylist(_ incoming: IncomingPlaylist, at index: Int?, onVideo: Bool) {
        guard let window else { return }
        let here = Library.shared.playlist(shownID)
        let a = NSAlert()
        var actions: [(String, () -> Void)] = []
        switch incoming {
        case .files(let urls):
            let read = urls.compactMap { u in PlaylistFile.readNamed(u).map { (u, $0.0, $0.1) } }
            guard let first = read.first else { return }
            let count = read.map(\.2.count).reduce(0, +)
            a.messageText = read.count == 1 ? "“\(first.1)” is a Reel playlist" : "These are \(read.count) Reel playlists"
            a.informativeText = "\(count) item\(count == 1 ? "" : "s"). What would you like to do with \(read.count == 1 ? "it" : "them")?"
            actions.append(("Play Without Saving", {
                let opened = read.compactMap { Library.shared.open(file: $0.0) }
                if let p = opened.first { self.delegate?.panelPlayOpened(p.id) }
            }))
            actions.append((read.count == 1 ? "Save as a New Playlist" : "Save as New Playlists", {
                var last: Playlist?
                for r in read { last = Library.shared.importPlaylist(named: r.1, tracks: r.2) }
                guard let p = last else { return }
                self.show(playlist: p.id, animated: true)
                self.delegate?.panelWantsToBeSeen()
                self.delegate?.panelNotice("Saved “\(p.name)” to your playlists", symbol: "square.and.arrow.down.fill", sticky: false)
                if (onVideo || (self.delegate?.isIdle ?? false)), let t = p.tracks.first(where: { $0.isPlayableInSequence }) {
                    self.delegate?.panelPlay(playlist: p.id, track: t.id)
                }
            }))
            if let here {
                actions.append(("Add Its Items to “\(here.name)”", {
                    self.insert(read.flatMap { $0.2.map { var t = $0; t.id = UUID(); return t } }, into: here.id, at: index, playFirst: onVideo)
                }))
            }
        case .youtube(let text, let links):
            let first = links[0]
            a.messageText = "That's a YouTube playlist"
            a.informativeText = "What would you like to do with it?"
            actions.append(("Play Without Saving", {
                self.resolve(text) { items in
                    Task { @MainActor in
                        let title = await MediaResolver.youtubePlaylistTitle(first.list) ?? "YouTube playlist"
                        let p = Library.shared.openUnsaved(named: title, tracks: items)
                        self.delegate?.panelPlayOpened(p.id)
                    }
                }
            }))
            actions.append(("Save as a New Playlist", {
                Task { @MainActor in
                    let title = await MediaResolver.youtubePlaylistTitle(first.list) ?? "YouTube playlist"
                    let p = Library.shared.addPlaylist(named: title)
                    self.show(playlist: p.id, animated: true)
                    self.addResolved(text: text, into: p.id, at: nil, playFirst: onVideo)
                }
            }))
            if let here {
                actions.append(("Add Its Videos to “\(here.name)”", { self.addResolved(text: text, into: here.id, at: index, playFirst: onVideo) }))
            }
            if first.video != nil {
                var single = text
                for l in links { if let v = l.video { single = single.replacingOccurrences(of: l.link, with: "https://youtu.be/\(v)") } }
                actions.append(("Only This Video", {
                    if onVideo { self.resolve(single) { self.delegate?.panelPlayLoose($0) } }
                    else { self.addResolved(text: single, into: self.shownID, at: index, playFirst: false) }
                }))
            }
        }
        for (title, _) in actions { a.addButton(withTitle: title) }
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { r in
            let i = r.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            if i >= 0, i < actions.count { actions[i].1() }
        }
    }

    /// Looks up the links in `text` (with the busy spinner and messages), then hands over what it found.
    private func resolve(_ text: String, then: @escaping ([Track]) -> Void) {
        let n = MediaResolver.linkCount(in: text)
        setBusy(+1)
        delegate?.panelNotice("Opening…", symbol: "link", sticky: true)
        Task { @MainActor in
            let items = await MediaResolver.tracks(forText: text)
            self.setBusy(-1)
            guard !items.isEmpty else {
                self.delegate?.panelNotice(n == 1 ? "Couldn't find anything to play at that link" : "Couldn't find anything to play at those links",
                                           symbol: "exclamationmark.triangle.fill", sticky: false)
                return
            }
            then(items)
        }
    }

    private func addResolved(text: String, into target: UUID, at index: Int?, playFirst: Bool) {
        let n = MediaResolver.linkCount(in: text)
        guard n > 0 else { delegate?.panelNotice("No links or files in that", symbol: "exclamationmark.triangle.fill", sticky: false); return }
        setBusy(+1)
        delegate?.panelNotice(n == 1 ? "Adding link…" : "Adding \(n) links…", symbol: "link", sticky: true)
        Task { @MainActor in
            let items = await MediaResolver.tracks(forText: text)
            self.setBusy(-1)
            if items.isEmpty {
                self.delegate?.panelNotice(n == 1 ? "Couldn't find anything to play at that link" : "Couldn't find anything to play at those links",
                                           symbol: "exclamationmark.triangle.fill", sticky: false)
                return
            }
            self.insert(items, into: target, at: index, playFirst: playFirst)
        }
    }

    func add(files: [URL], at index: Int?, playFirst: Bool = false) {
        // Playlist files (.reel, older .json) ask what to do; everything else is media.
        let lists = files.filter { PlaylistFile.readNamed($0) != nil }
        let media = files.filter { !lists.contains($0) }
        if !lists.isEmpty {
            askAboutPlaylist(.files(lists), at: index, onVideo: false)
            if media.isEmpty { return }
        }
        let items = MediaResolver.tracks(forFiles: media)
        if items.isEmpty {
            delegate?.panelNotice(media.count == 1 ? "That isn't a video or audio file" : "No video or audio files in there",
                                  symbol: "exclamationmark.triangle.fill", sticky: false)
            return
        }
        insert(items, into: shownID, at: index, playFirst: playFirst)
    }

    private func insert(_ items: [Track], into id: UUID, at index: Int?, playFirst: Bool) {
        var at = 0
        Library.shared.mutate(id) { p in
            at = min(index ?? p.tracks.count, p.tracks.count)
            p.tracks.insert(contentsOf: items, at: at)
        }
        let name = Library.shared.playlist(id)?.name ?? "playlist"
        let willPlay = playFirst || (delegate?.isIdle ?? false)
        let what = items.count == 1 ? "“\(items[0].displayName)”" : "\(items.count) items"
        delegate?.panelNotice(willPlay && items.count == 1 ? "Playing \(what)" : "Added \(what) to “\(name)”",
                              symbol: willPlay ? "play.circle.fill" : "plus.circle.fill", sticky: false)
        // Open the playlist and select the new rows so you can see where they went.
        if id != shownID || mode == .playlists { show(playlist: id, animated: true) }
        delegate?.panelWantsToBeSeen()
        let rows = IndexSet(at..<min(at + items.count, table.numberOfRows))
        table.selectRowIndexes(rows, byExtendingSelection: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {   // after the playlist has opened
            guard let last = rows.last, let firstRow = rows.first else { return }
            self.table.scrollRowToVisible(last)
            self.table.scrollRowToVisible(firstRow)
        }
        if willPlay, let first = items.first {
            delegate?.panelPlay(playlist: id, track: first.id)
        }
    }

    // MARK: Loose items (playing, but not in a playlist)

    func refreshLoose() {
        let shown = Library.shared.playlist(shownID)
        let unsaved = shown?.isUnsaved == true
        if unsaved != !saveBar.isHidden { saveBar.isHidden = !unsaved; needsLayout = true }
        if unsaved, let shown {
            saveBar.set(title: shown.name, tip: "Keep “\(shown.name)” with your playlists")
        }
        let info = delegate?.looseInfo
        let wasHidden = looseBar.isHidden
        looseBar.isHidden = info == nil
        if let info {
            let name = Library.shared.playlist(shownID)?.name ?? "this playlist"
            looseBar.set(title: info.count > 1 ? "\(info.title) + \(info.count - 1) more" : info.title,
                         tip: "Add \(info.count == 1 ? "it" : "all \(info.count)") to “\(name)” — the one shown here")
        }
        if wasHidden != looseBar.isHidden { needsLayout = true }
    }

    @objc private func addLooseClicked() { delegate?.panelAddLoose() }
    @objc private func saveClicked() { save(shownID) }

    /// Keeps a playlist opened from a .reel file.
    func save(_ id: UUID) {
        Library.shared.save(id)
        let name = Library.shared.playlist(id)?.name ?? "playlist"
        delegate?.panelNotice("Saved “\(name)” to your playlists", symbol: "checkmark.circle.fill", sticky: false)
        refreshLoose()
    }
    var debugLooseBar: LooseBar { looseBar }
    var debugSaveBarShown: Bool { !saveBar.isHidden }
    var countLabelText: String { countLabel.stringValue }

    /// Selects these tracks and scrolls to them (after they were added).
    func reveal(trackIDs: [UUID]) {
        let rows = IndexSet(tracks.enumerated().filter { trackIDs.contains($0.element.id) }.map(\.offset))
        table.selectRowIndexes(rows, byExtendingSelection: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let last = rows.last, let first = rows.first else { return }
            self.table.scrollRowToVisible(last)
            self.table.scrollRowToVisible(first)
        }
    }

    /// Where something pasted with the pointer at this spot (window coordinates) would go: before the row
    /// under the pointer (after it, in its lower half), the end of the list below the last row, nil outside the list.
    func insertionRow(atWindowPoint wp: NSPoint) -> Int? {
        guard !isHidden, mode == .tracks, scroll.convert(scroll.bounds, to: self).contains(convert(wp, from: nil)) else { return nil }
        let tp = table.convert(wp, from: nil)
        let r = table.row(at: tp)
        guard r >= 0 else { return tracks.count }
        return tp.y < table.rect(ofRow: r).midY ? r : r + 1      // the table is flipped: smaller y is higher
    }

    // MARK: Drop highlight

    struct DropSummary { var detail: String; var isPlaylist: Bool }

    /// What's being dragged, in a few words — or nil if there's nothing Reel can add in it.
    static func dropSummary(_ pb: NSPasteboard) -> DropSummary? {
        if let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            let lists = files.filter { ["reel", "json"].contains($0.pathExtension.lowercased()) }
            if files.count == 1 {
                let f = files[0]
                if !lists.isEmpty { return DropSummary(detail: "“\(f.deletingPathExtension().lastPathComponent)”", isPlaylist: true) }
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: f.path, isDirectory: &isDir), isDir.boolValue {
                    return DropSummary(detail: "Folder “\(f.lastPathComponent)”", isPlaylist: false)
                }
                return DropSummary(detail: "“\(f.deletingPathExtension().lastPathComponent)”", isPlaylist: false)
            }
            return DropSummary(detail: "\(files.count) items", isPlaylist: lists.count == files.count)
        }
        let n = MediaResolver.linkCount(in: pasteboardText(pb))
        return n == 0 ? nil : DropSummary(detail: n == 1 ? "1 link" : "\(n) links", isPlaylist: false)
    }

    /// Shows the outline over the playlist; false if the drag has nothing addable.
    func showDropHighlight(_ pb: NSPasteboard) -> Bool {
        guard let s = Self.dropSummary(pb) else { dropHighlight.hide(); return false }
        let name = Library.shared.playlist(shownID)?.name ?? "playlist"
        dropHighlight.show(title: s.isPlaylist ? "Drop to open playlist" : "Add to “\(name)”", detail: s.detail)
        return true
    }

    private func setBusy(_ d: Int) {
        resolving += d
        if resolving > 0 { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    // MARK: Drag & drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: reorderType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        if let src = info.draggingSource as? NSTableView, src === table || src === playlistTable {
            guard src === tableView else { return [] }          // reorder within the same list only
            tableView.setDropRow(row, dropOperation: .above); return .move
        }
        if tableView === playlistTable {
            // onto a playlist: add it there
            let all = Library.shared.playlists
            guard !all.isEmpty, let s = Self.dropSummary(info.draggingPasteboard), !s.isPlaylist else { dropHighlight.hide(); return [] }
            let r = max(0, min(row, all.count - 1))
            tableView.setDropRow(r, dropOperation: .on)
            dropHighlight.show(title: "Add to “\(all[r].name)”", detail: s.detail)
            return .copy
        }
        guard showDropHighlight(info.draggingPasteboard) else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        dropHighlight.hide()
        let pb = info.draggingPasteboard
        if tableView === playlistTable, info.draggingSource as? NSTableView === playlistTable {
            let rows = (pb.pasteboardItems ?? []).compactMap { $0.string(forType: reorderType).flatMap(Int.init) }
            Library.shared.movePlaylists(rows, to: row)
            return true
        }
        if tableView === playlistTable {
            guard row >= 0, row < Library.shared.playlists.count else { return false }
            show(playlist: Library.shared.playlists[row].id, animated: true)
            return acceptExternal(pb, at: nil)
        }
        if info.draggingSource as? NSTableView === table {
            let rows = (pb.pasteboardItems ?? []).compactMap { $0.string(forType: reorderType).flatMap(Int.init) }.sorted()
            Library.shared.mutate(shownID) { p in
                let moving = rows.filter { $0 < p.tracks.count }.map { p.tracks[$0] }
                let before = rows.filter { $0 < row }.count
                for r in rows.reversed() where r < p.tracks.count { p.tracks.remove(at: r) }
                p.tracks.insert(contentsOf: moving, at: min(row - before, p.tracks.count))
            }
            return true
        }
        return acceptExternal(pb, at: row)
    }

    /// Shared with the video area and ⌘V. Takes files, or every link found in the URLs/text on the pasteboard.
    @discardableResult
    func acceptExternal(_ pb: NSPasteboard, at row: Int?, playFirst: Bool = false) -> Bool {
        if let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            add(files: files, at: row, playFirst: playFirst); return true
        }
        let text = Self.pasteboardText(pb)
        guard !text.isEmpty else { return false }
        add(text: text, at: row, playFirst: playFirst)
        return true
    }

    /// Every URL / line of text on the pasteboard, de-duplicated, one per line.
    static func pasteboardText(_ pb: NSPasteboard) -> String {
        var lines: [String] = []
        for item in pb.pasteboardItems ?? [] {
            if let u = item.string(forType: .URL) { lines.append(u) }
            if let t = item.string(forType: .string) { lines.append(t) }
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] { lines += urls.map(\.absoluteString) }
        var seen = Set<String>()
        return lines.flatMap { $0.components(separatedBy: .newlines) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: "\n")
    }

    // Header / transport bar area (the list handles its own drops above).
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { showDropHighlight(sender.draggingPasteboard) ? .copy : [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropHighlight.hide() }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropHighlight.hide() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlight.hide()
        return acceptExternal(sender.draggingPasteboard, at: nil)
    }
}

/// "Not in a playlist · <title>  [Add]" — sits above the list while a loose item plays.
final class LooseBar: NSView {
    private let caption = NSTextField(labelWithString: "Not in a playlist")
    private let title = NSTextField(labelWithString: "")
    let button = NSButton(title: "Add", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        caption.font = .systemFont(ofSize: 10, weight: .medium)
        caption.textColor = NSColor.white.withAlphaComponent(0.5)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        button.controlSize = .small
        button.bezelStyle = .push
        button.font = .systemFont(ofSize: 11, weight: .medium)
        [caption, title, button].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { false }

    convenience init(caption c: String, buttonTitle b: String) {
        self.init(frame: .zero)
        caption.stringValue = c
        button.title = b
    }

    func set(title t: String, tip: String) {
        title.stringValue = t
        title.toolTip = t
        button.toolTip = tip
    }

    override func layout() {
        super.layout()
        button.sizeToFit()
        let bw = button.frame.width
        button.frame = NSRect(x: bounds.width - bw - 6, y: (bounds.height - button.frame.height) / 2, width: bw, height: button.frame.height)
        let tw = button.frame.minX - 10 - 6
        caption.frame = NSRect(x: 10, y: bounds.height - 18, width: tw, height: 13)
        title.frame = NSRect(x: 10, y: 6, width: tw, height: 17)
    }
}

final class RoundedRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        NSColor.white.withAlphaComponent(isEmphasized ? 0.16 : 0.1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 0), xRadius: 6, yRadius: 6).fill()
    }
}

/// Knob only — never draws the scroll track behind it.
/// The lists' scroll views: up/down scrolls as usual; a sideways two-finger swipe goes to `onSwipe`
/// (switching between all playlists and the shown playlist).
final class PaneScrollView: NSScrollView {
    var onSwipe: ((NSEvent) -> Bool)?
    override func scrollWheel(with event: NSEvent) {
        if onSwipe?(event) == true { return }
        super.scrollWheel(with: event)
    }
}

final class TracklessScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}
