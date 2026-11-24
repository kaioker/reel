import AppKit
import UniformTypeIdentifiers

protocol PlaylistPanelDelegate: AnyObject {
    var nowPlayingTrackID: UUID? { get }
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
}

private let reorderType = NSPasteboard.PasteboardType("app.reel.track-rows")

/// Label you can triple-click to rename.
final class TripleClickField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    private var original = ""
    private(set) var editingName = false
    /// Cells in the track table let the table decide (so it can cancel a pending double-click play).
    var handlesRenameClick = true

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

    let nameField = TripleClickField()
    private lazy var switchBtn = IconButton("chevron.down", size: 10, tip: "Switch playlist", target: self, action: #selector(showPlaylistMenu))
    private let countLabel = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    let table = TrackTable()
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
    private lazy var exportBtn = IconButton("square.and.arrow.up", size: 13, tip: "Export this playlist (drop the file on Reel to import it)", target: self, action: #selector(exportPlaylist))
    private let transportBar = NSView()
    private let spinner = NSProgressIndicator()
    private let emptyHint = NSTextField(wrappingLabelWithString: "Drop files, folders or links here,\npress ⌘V to paste links,\nor click + to choose files.\n\nClick a track to play it.\nDouble-click a title to rename it.")
    private let divider = NSBox()
    let dropHighlight: DropHighlight = { let d = DropHighlight(); d.dims = false; return d }()
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

        nameField.configureAsLabel(size: 13, weight: .semibold)
        nameField.textColor = .white
        nameField.toolTip = "Double-click to rename"
        nameField.onCommit = { [weak self] v in
            guard let self else { return }
            let name = v.trimmingCharacters(in: .whitespaces)
            Library.shared.mutate(self.shownID) { if !name.isEmpty { $0.name = name } }
            self.reloadHeader()
        }
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = NSColor.white.withAlphaComponent(0.5)

        let col = NSTableColumn(identifier: .init("t"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 42
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.focusRingType = .none
        table.registerForDraggedTypes([reorderType, .fileURL, .URL, .string])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.onPlay = { [weak self] row in self?.play(row: row) }
        table.onRename = { [weak self] row, pt in
            guard let self, let cell = self.table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TrackCell else { return }
            if cell.titleHit(pt) { cell.title.beginRename() }
        }
        table.onDelete = { [weak self] in self?.removeSelected() }
        table.onRightClick = { [weak self] row, e in self?.showContextMenu(row: row, event: e) }

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScroller = TracklessScroller()
        scroll.verticalScroller?.knobStyle = .light

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        emptyHint.alignment = .center
        emptyHint.font = .systemFont(ofSize: 12)
        emptyHint.textColor = NSColor.white.withAlphaComponent(0.45)

        divider.boxType = .separator

        transportBar.wantsLayer = true
        transportBar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        [prevBtn, playBtn, nextBtn, loopBtn, spinner, addBtn, exportBtn].forEach(transportBar.addSubview)
        setTransport(playing: false, loop: false, hasTrack: false)
        [divider, nameField, switchBtn, countLabel, scroll, emptyHint, transportBar, dropHighlight].forEach(addSubview)
        registerForDraggedTypes([.fileURL, .URL, .string])
        table.onDragExit = { [weak self] in self?.dropHighlight.hide() }

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
        [nameField, switchBtn].forEach { $0.isHidden = !showHeader }
        countLabel.isHidden = !showCount
        transportBar.isHidden = !showBar
        // Playlist name sits on the same line as the window buttons, chevron right after it.
        let cy = H - titleRowCenterFromTop
        let maxNameW = W - 14 - titleRowRightInset - 26
        let textW = nameField.editingName ? maxNameW : min(maxNameW, ceil(nameField.attributedStringValue.size().width) + 6)
        nameField.frame = NSRect(x: 14, y: cy - 9, width: textW, height: 18)
        switchBtn.frame = NSRect(x: nameField.frame.maxX + 1, y: cy - 11, width: 22, height: 22)
        countLabel.frame = NSRect(x: 15, y: cy - 28, width: W - 30, height: 15)
        let top = showCount ? cy - 32 : cy - 14

        let barH: CGFloat = showBar ? 34 : 0
        transportBar.frame = NSRect(x: 0, y: 0, width: W, height: barH)
        let by: CGFloat = 5, bh: CGFloat = 24
        prevBtn.frame = NSRect(x: 10, y: by, width: 26, height: bh)
        playBtn.frame = NSRect(x: 38, y: by, width: 28, height: bh)
        nextBtn.frame = NSRect(x: 68, y: by, width: 26, height: bh)
        loopBtn.frame = NSRect(x: 102, y: by, width: 26, height: bh)
        exportBtn.frame = NSRect(x: W - 62, y: by - 1, width: 26, height: bh)
        addBtn.frame = NSRect(x: W - 36, y: by, width: 26, height: bh)
        spinner.frame = NSRect(x: W - 86, y: by + 4, width: 16, height: 16)

        scroll.frame = NSRect(x: 4, y: barH, width: W - 8, height: max(0, top - barH))
        table.tableColumns.first?.width = scroll.contentSize.width
        emptyHint.frame = NSRect(x: 20, y: scroll.frame.midY - 45, width: W - 40, height: 90)
        emptyHint.isHidden = !tracks.isEmpty || H < 170
        dropHighlight.frame = bounds
        dropHighlight.labelBottomInset = barH
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

    @objc func exportPlaylist() {
        guard let p = Library.shared.playlist(shownID), let window else { return }
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
    @objc private func tAdd() { delegate?.panelOpenFiles() }

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
        for r in 0..<table.numberOfRows {
            if let c = table.view(atColumn: 0, row: r, makeIfNecessary: false) as? TrackCell, c.title.editingName { return true }
        }
        return false
    }

    func reloadAll() {
        let selectedIDs = Set(table.selectedRowIndexes.compactMap { $0 < tracks.count ? tracks[$0].id : nil })
        reloadHeader()
        table.reloadData()
        let idx = IndexSet(tracks.enumerated().filter { selectedIDs.contains($0.element.id) }.map(\.offset))
        table.selectRowIndexes(idx, byExtendingSelection: false)
        emptyHint.isHidden = !tracks.isEmpty || bounds.height < 160
    }

    private func reloadHeader() {
        let p = Library.shared.playlist(shownID)
        nameField.stringValue = p?.name ?? ""
        needsLayout = true
        let ts = p?.tracks ?? []
        let total = ts.compactMap(\.duration).reduce(0, +)
        var s = "\(ts.count) item\(ts.count == 1 ? "" : "s")"
        if total > 0 { s += " · " + formatTime(total) }
        countLabel.stringValue = s
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
        if let row = currentRow, isRowVisible(row) { followsCurrent = true }
        DispatchQueue.main.async { self.revealCurrent() }
        for r in 0..<table.numberOfRows {
            if let c = table.view(atColumn: 0, row: r, makeIfNecessary: false) as? TrackCell { configure(c, row: r) }
        }
    }

    func show(playlist id: UUID) {
        shownID = id
        Prefs.lastPlaylist = id.uuidString
        reloadAll()
        followsCurrent = true
        DispatchQueue.main.async { self.revealCurrent(animated: false) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tracks.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: .init("cell"), owner: self) as? TrackCell) ?? {
            let c = TrackCell(); c.identifier = .init("cell"); return c
        }()
        configure(cell, row: row)
        return cell
    }

    private func configure(_ cell: TrackCell, row: Int) {
        guard row < tracks.count else { return }
        let t = tracks[row]
        cell.trackID = t.id
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

    @objc private func showPlaylistMenu() {
        let m = NSMenu()
        for p in Library.shared.playlists {
            let i = NSMenuItem(title: "\(p.name)  (\(p.tracks.count))", action: #selector(pickPlaylist(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = p.id; i.state = p.id == shownID ? .on : .off
            m.addItem(i)
        }
        m.addItem(.separator())
        let n = NSMenuItem(title: "New Playlist", action: #selector(newPlaylist), keyEquivalent: ""); n.target = self; m.addItem(n)
        let c = NSMenuItem(title: "Clear Playlist", action: #selector(clearPlaylist), keyEquivalent: ""); c.target = self; m.addItem(c)
        let d = NSMenuItem(title: "Delete Playlist…", action: #selector(deletePlaylist), keyEquivalent: ""); d.target = self; m.addItem(d)
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: switchBtn.bounds.height + 2), in: switchBtn)
    }
    @objc private func pickPlaylist(_ s: NSMenuItem) { if let id = s.representedObject as? UUID { show(playlist: id) } }
    @objc func newPlaylist() {
        let p = Library.shared.addPlaylist(named: Library.shared.nextPlaylistName())
        show(playlist: p.id)
    }
    @objc private func clearPlaylist() { Library.shared.mutate(shownID) { $0.tracks.removeAll() } }
    @objc private func deletePlaylist() {
        guard let p = Library.shared.playlist(shownID) else { return }
        let a = NSAlert()
        a.messageText = "Delete “\(p.name)”?"
        a.informativeText = p.tracks.isEmpty ? "" : "Its \(p.tracks.count) items will be removed. Files on disk are not touched."
        a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
        a.buttons[0].hasDestructiveAction = true
        guard let w = window else { return }
        a.beginSheetModal(for: w) { r in
            if r == .alertFirstButtonReturn { Library.shared.removePlaylist(p.id); self.show(playlist: Library.shared.playlists[0].id) }
        }
    }

    // MARK: Adding

    /// Adds resolved items to the shown playlist; autoplays the first one if nothing is playing.
    /// A YouTube *playlist* link first asks: just this video, all its videos, or a new playlist.
    func add(text: String, at index: Int?, playFirst: Bool = false) {
        let ytLists = MediaResolver.youtubePlaylistLinks(in: text)
        guard let first = ytLists.first, let window else { addResolved(text: text, into: shownID, at: index, playFirst: playFirst); return }
        let a = NSAlert()
        a.messageText = "That's a YouTube playlist"
        a.informativeText = "How should Reel add it?"
        a.addButton(withTitle: "All Videos")
        a.addButton(withTitle: "New Playlist")
        if first.video != nil { a.addButton(withTitle: "Just This Video") }
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { r in
            switch r {
            case .alertFirstButtonReturn:
                self.addResolved(text: text, into: self.shownID, at: index, playFirst: playFirst)
            case .alertSecondButtonReturn:
                Task { @MainActor in
                    let title = await MediaResolver.youtubePlaylistTitle(first.list) ?? "YouTube playlist"
                    let p = Library.shared.addPlaylist(named: title)
                    self.show(playlist: p.id)
                    self.addResolved(text: text, into: p.id, at: nil, playFirst: playFirst)
                }
            case .alertThirdButtonReturn where first.video != nil:
                var single = text
                for l in ytLists { if let v = l.video { single = single.replacingOccurrences(of: l.link, with: "https://youtu.be/\(v)") } }
                self.addResolved(text: single, into: self.shownID, at: index, playFirst: playFirst)
            default: break
            }
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
        // Exported playlists (.json) import as new playlists; everything else is media.
        var media: [URL] = []
        var imported: Playlist?
        for f in files {
            if let (name, ts) = PlaylistFile.readNamed(f) { imported = Library.shared.importPlaylist(named: name, tracks: ts) } else { media.append(f) }
        }
        if let p = imported {
            show(playlist: p.id)
            delegate?.panelWantsToBeSeen()
            delegate?.panelNotice("Imported “\(p.name)” · \(p.tracks.count) item\(p.tracks.count == 1 ? "" : "s")", symbol: "square.and.arrow.down.fill", sticky: false)
            if (playFirst || (delegate?.isIdle ?? false)) && media.isEmpty, let first = p.tracks.first {
                delegate?.panelPlay(playlist: p.id, track: first.id)
            }
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
        if id != shownID { show(playlist: id) }
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
        dropHighlight.show(title: s.isPlaylist ? "Import as a new playlist" : "Add to “\(name)”", detail: s.detail)
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
        if info.draggingSource as? NSTableView === table { tableView.setDropRow(row, dropOperation: .above); return .move }
        guard showDropHighlight(info.draggingPasteboard) else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        dropHighlight.hide()
        let pb = info.draggingPasteboard
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

final class RoundedRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        NSColor.white.withAlphaComponent(isEmphasized ? 0.16 : 0.1).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 0), xRadius: 6, yRadius: 6).fill()
    }
}

/// Knob only — never draws the scroll track behind it.
final class TracklessScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}
