import AppKit
import UniformTypeIdentifiers

/// Shuffle, playback speed, "stop after this", frame stepping, per-video resume, and the audio-track and
/// subtitle choices — the state behind them lives here; `PlayerController` calls in at a few points.
final class PlaybackExtras: NSObject, NSMenuDelegate {
    unowned let player: PlayerController
    init(player: PlayerController) { self.player = player }

    // MARK: Shuffle

    /// Tracks not yet played in this round of shuffling, and the ones played (for ⏮).
    private var bag: [UUID] = []
    private var history: [UUID] = []
    private var bagFor: UUID?

    var shuffle: Bool { Prefs.shuffle }

    func toggleShuffle() {
        Prefs.shuffle.toggle()
        bag = []; history = []; bagFor = nil
        player.toast.show(shuffle ? "Shuffle on" : "Shuffle off", symbol: shuffle ? "shuffle" : "arrow.right", sticky: false)
        player.updateHUDState()
    }

    /// The next track when shuffling: every playable track once, in random order, then a new order.
    func shuffledNext() -> UUID? {
        guard shuffle, let c = player.current, c.playlist != player.transientID, let p = player.list(c.playlist) else { return nil }
        if bagFor != p.id { bag = []; history = []; bagFor = p.id }
        let playable = p.tracks.filter(\.isPlayableInSequence).map(\.id)
        bag = bag.filter { playable.contains($0) && $0 != c.track }
        if bag.isEmpty { bag = playable.filter { $0 != c.track }.shuffled() }
        guard !bag.isEmpty else { return nil }
        history.append(c.track)
        return bag.removeFirst()
    }

    /// ⏮ while shuffling goes back through what actually played.
    func shuffledPrevious() -> UUID? {
        guard shuffle, let c = player.current, let p = player.list(c.playlist) else { return nil }
        while let id = history.popLast() {
            if p.tracks.contains(where: { $0.id == id && $0.isAvailable }) { bag.insert(c.track, at: 0); return id }
        }
        return nil
    }

    // MARK: Speed

    static let speeds: [Float] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    private(set) var speed: Float = 1

    func setSpeed(_ s: Float) {
        speed = max(0.25, min(2, s))
        player.backend?.rate = speed
        player.debugNowPlaying.speed = Double(speed)
        player.updateNowPlaying(force: true)
        let live = player.backend?.isLive == true && speed != 1
        player.toast.show(live ? "Speed \(Self.label(speed)) · live streams play at normal speed"
                               : speed == 1 ? "Normal speed" : "Speed \(Self.label(speed))",
                          symbol: "gauge.with.dots.needle.50percent", sticky: false)
    }
    func faster() { setSpeed(Self.speeds.first { $0 > speed + 0.001 } ?? speed) }
    func slower() { setSpeed(Self.speeds.last { $0 < speed - 0.001 } ?? speed) }
    static func label(_ s: Float) -> String {
        let f = NumberFormatter(); f.minimumFractionDigits = 0; f.maximumFractionDigits = 2
        return (f.string(from: NSNumber(value: s)) ?? "\(s)") + "×"
    }

    // MARK: Stop after this

    var stopAfterCurrent = false
    func toggleStopAfter() {
        stopAfterCurrent.toggle()
        player.toast.show(stopAfterCurrent ? "Will stop after this one" : "Will keep playing", symbol: "stop.circle", sticky: false)
    }

    // MARK: Frame stepping

    func step(_ frames: Int) {
        guard let b = player.backend, player.current != nil else { return }
        b.step(frames: frames)
        player.flash.isHidden = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.player.updateHUDState(); self.subtitleTick() }
    }

    // MARK: Resume each video where you left it (long videos)

    static let resumeMinDuration: Double = 10 * 60
    private static let key = "positions"

    /// Where you stopped watching a long video (by its source, so the same video in any playlist).
    static func position(for t: Track) -> Double? {
        let d = UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]]
        return d?[t.source]?.first
    }

    /// Remembers the spot in a long video (more than 30 s in and 30 s from the end); forgets it otherwise.
    func remember(_ t: Track, at time: Double, duration: Double) {
        var d = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: [Double]] ?? [:]
        if duration >= Self.resumeMinDuration && time > 30 && time < duration - 30 {
            d[t.source] = [time, Date().timeIntervalSince1970]
            if d.count > 300 {                                   // keep the most recent 300
                for (k, _) in d.sorted(by: { ($0.value.last ?? 0) < ($1.value.last ?? 0) }).prefix(d.count - 300) { d[k] = nil }
            }
        } else if d[t.source] != nil {
            d[t.source] = nil
        } else { return }
        UserDefaults.standard.set(d, forKey: Self.key)
    }

    func rememberCurrent() {
        guard let t = player.currentTrack, let b = player.backend, b.duration > 0 else { return }
        remember(t, at: b.currentTime, duration: b.duration)
    }

    func forget(_ t: Track) {
        var d = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: [Double]] ?? [:]
        guard d[t.source] != nil else { return }
        d[t.source] = nil
        UserDefaults.standard.set(d, forKey: Self.key)
    }

    // MARK: Subtitles

    enum SubtitleSource {
        case file(URL)
        case embedded(URL, index: Int32)
        case youtube(code: String)
    }
    private(set) var subtitleChoices: [(name: String, source: SubtitleSource)] = []
    private(set) var subtitleChoice: Int?
    private var lastSubtitleChoice: Int?
    private var cues: [SubtitleCue] = []
    private var subtitleTimer: Timer?
    private var loadToken = 0
    let overlay = SubtitleOverlay()
    /// The playing track's source: subtitle choices are remembered per track (any playlist it's in).
    private var trackKey: String?

    // Subtitles start off. What you pick for a track (or turning them off) is remembered for that track.
    private static let prefsKey = "subtitlePrefs"
    private func savedPreference() -> String? {
        trackKey.flatMap { (UserDefaults.standard.dictionary(forKey: Self.prefsKey) as? [String: String])?[$0] }
    }
    private func savePreference(_ choice: Int?) {
        guard let trackKey else { return }
        var d = UserDefaults.standard.dictionary(forKey: Self.prefsKey) as? [String: String] ?? [:]
        d[trackKey] = choice.map { Self.identity(subtitleChoices[$0].source) }
        UserDefaults.standard.set(d, forKey: Self.prefsKey)
    }
    private static func identity(_ s: SubtitleSource) -> String {
        switch s {
        case .file(let u): return "file:" + u.path
        case .embedded(_, let i): return "stream:\(i)"
        case .youtube(let c): return "yt:" + c
        }
    }
    /// Puts back the subtitles you chose for this track, once they're found (files, streams and captions arrive separately).
    private func restorePreference() {
        guard subtitleChoice == nil, let want = savedPreference() else { return }
        if let i = subtitleChoices.firstIndex(where: { Self.identity($0.source) == want }) {
            selectSubtitle(i, quiet: true, remember: false)
        } else if want.hasPrefix("file:") {
            let u = URL(fileURLWithPath: String(want.dropFirst(5)))
            guard FileManager.default.fileExists(atPath: u.path) else { return }
            subtitleChoices.append((Self.fileName(u, base: nil), .file(u)))      // a file you added for this track
            selectSubtitle(subtitleChoices.count - 1, quiet: true, remember: false)
        }
    }

    /// A new track: find subtitle files beside it and subtitles inside it — all off unless you chose them for this track.
    func trackChanged(_ t: Track) {
        loadToken += 1
        trackKey = t.source
        subtitleChoices = []; subtitleChoice = nil; lastSubtitleChoice = nil
        cues = []; overlay.show(nil); stopSubtitleTimer()
        if t.kind == .youtube { restorePreference() }
        guard (t.kind == .local || t.kind == .remote), let url = t.url else { return }
        if url.isFileURL {
            let dir = url.deletingLastPathComponent(), base = url.deletingPathExtension().lastPathComponent.lowercased()
            let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { SubtitleReader.fileExtensions.contains($0.pathExtension.lowercased()) }
                .filter { let n = $0.deletingPathExtension().lastPathComponent.lowercased(); return n == base || n.hasPrefix(base + ".") }
                .sorted { $0.lastPathComponent.count < $1.lastPathComponent.count }
            for f in files { subtitleChoices.append((Self.fileName(f, base: base), .file(f))) }
        }
        restorePreference()
        // Subtitles inside the file are listed by opening it a second time — never for a stream: that would be a
        // second connection (cameras and single-viewer servers allow one), or a clash over a UDP port.
        guard !t.isStream else { return }
        let token = loadToken
        DispatchQueue.global(qos: .utility).async {
            let streams = SubtitleReader.streams(in: url)
            DispatchQueue.main.async {
                guard token == self.loadToken, !streams.isEmpty else { return }
                self.subtitleChoices += streams.map { ($0.name + ($0.isPicture ? " (picture)" : ""), .embedded(url, index: $0.index)) }
                self.restorePreference()
            }
        }
    }

    /// YouTube's own captions, once the video says what it has.
    func youtubeCaptions(_ list: [(code: String, name: String)]) {
        let keep = subtitleChoices.filter { if case .youtube = $0.source { return false } else { return true } }
        subtitleChoices = keep + list.map { ($0.name, .youtube(code: $0.code)) }
        restorePreference()
    }

    /// A subtitle file dropped on the video or picked with Add Subtitle File…: use it for what's playing.
    func addSubtitleFile(_ url: URL) {
        guard player.current != nil else { player.toast.show("Play something first, then add its subtitles", symbol: "captions.bubble", sticky: false); return }
        subtitleChoices.append((Self.fileName(url, base: nil), .file(url)))
        selectSubtitle(subtitleChoices.count - 1)
    }

    /// `remember`: it's your choice for this track (not a restore), so keep it for next time.
    func selectSubtitle(_ i: Int?, quiet: Bool = false, remember: Bool = true) {
        if remember { savePreference(i.flatMap { $0 >= 0 && $0 < subtitleChoices.count ? $0 : nil }) }
        if let old = subtitleChoice, case .youtube = subtitleChoices[old].source, i == nil || i != old { player.ytCaptions(nil) }
        guard let i, i >= 0, i < subtitleChoices.count else {
            if subtitleChoice != nil { lastSubtitleChoice = subtitleChoice }
            subtitleChoice = nil; cues = []; overlay.show(nil); stopSubtitleTimer()
            if !quiet { player.toast.show("Subtitles off", symbol: "captions.bubble", sticky: false) }
            return
        }
        subtitleChoice = i
        lastSubtitleChoice = i
        cues = []; overlay.show(nil)
        let choice = subtitleChoices[i]
        if !quiet { player.toast.show("Subtitles: \(choice.name)", symbol: "captions.bubble.fill", sticky: false) }
        switch choice.source {
        case .youtube(let code):
            stopSubtitleTimer()
            player.ytCaptions(code)
        case .file(let url), .embedded(let url, _):
            var index: Int32?
            if case .embedded(_, let n) = choice.source { index = n }
            loadToken += 1
            let token = loadToken
            let remote = !url.isFileURL
            if remote && !quiet { player.toast.show("Loading subtitles…", symbol: "captions.bubble", sticky: true) }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let read = SubtitleReader.read(url, stream: index) { [weak self] in self?.loadToken != token }
                DispatchQueue.main.async {
                    guard let self, token == self.loadToken, self.subtitleChoice == i else { return }
                    self.cues = read
                    if read.isEmpty { self.warnNoSubtitles("No subtitles found in “\(choice.name)”") ; return }
                    if remote && !quiet { self.player.toast.show("Subtitles: \(choice.name)", symbol: "captions.bubble.fill", sticky: false) }
                    self.startSubtitleTimer()
                }
            }
        }
    }

    /// V: subtitles on (the last ones used, or the first) / off.
    func toggleSubtitles() {
        if subtitleChoice != nil { selectSubtitle(nil); return }
        guard !subtitleChoices.isEmpty else { warnNoSubtitles("No subtitles for this video"); return }
        selectSubtitle(lastSubtitleChoice.flatMap { $0 < subtitleChoices.count ? $0 : nil } ?? 0)
    }

    /// Turned on, but there's nothing to show: say so, then switch them off again (and keep that for this track).
    private func warnNoSubtitles(_ message: String) {
        player.toast.show(message, symbol: "exclamationmark.triangle.fill", sticky: false)
        let token = loadToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard token == self.loadToken else { return }          // a different track by now
            self.selectSubtitle(nil, quiet: true)
            self.player.toast.show("Subtitles off", symbol: "captions.bubble", sticky: false)
        }
    }

    private static func fileName(_ f: URL, base: String?) -> String {
        var n = f.deletingPathExtension().lastPathComponent
        if let base, n.lowercased().hasPrefix(base + ".") { n = String(n.dropFirst(base.count + 1)) }   // "movie.en.srt" → "en"
        else if let base, n.lowercased() == base { n = "Subtitle file" }
        if n.count <= 3, let lang = Locale.current.localizedString(forLanguageCode: n) { n = lang }
        return n + " (\(f.pathExtension.lowercased()))"
    }

    private func startSubtitleTimer() {
        stopSubtitleTimer()
        guard !cues.isEmpty else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.subtitleTick() }
        RunLoop.main.add(t, forMode: .common)
        subtitleTimer = t
        subtitleTick()
    }
    private func stopSubtitleTimer() { subtitleTimer?.invalidate(); subtitleTimer = nil }

    func subtitleTick() {
        guard !cues.isEmpty, let b = player.backend else { return }
        let t = b.currentTime
        // last cue starting at or before now (binary search), shown while it lasts
        var lo = 0, hi = cues.count - 1, found = -1
        while lo <= hi { let m = (lo + hi) / 2; if cues[m].start <= t { found = m; lo = m + 1 } else { hi = m - 1 } }
        var showing: SubtitleCue?
        if found >= 0 {
            // overlapping cues (two speakers): show every one still on screen, text joined
            let live = cues[max(0, found - 4)...found].filter { $0.start <= t && t < $0.end }
            if let pic = live.last(where: { $0.image != nil }) { showing = pic }
            else if !live.isEmpty {
                showing = SubtitleCue(start: live[0].start, end: live.map(\.end).max()!, text: live.compactMap(\.text).joined(separator: "\n"))
            }
        }
        overlay.show(showing)
    }

    // MARK: Menus (Playback → Speed / Audio Track / Subtitles, and the video's right-click)

    enum MenuKind: Int { case speed = 1, audio, subtitles }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        switch MenuKind(rawValue: menu.identifier.map { Int($0.rawValue) ?? 0 } ?? 0) {
        case .speed: fillSpeed(menu)
        case .audio: fillAudio(menu)
        case .subtitles: fillSubtitles(menu)
        case nil: break
        }
    }

    static func submenu(_ title: String, _ kind: MenuKind, delegate: PlaybackExtras) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title)
        m.identifier = NSUserInterfaceItemIdentifier(String(kind.rawValue))
        m.delegate = delegate
        item.submenu = m
        return item
    }

    private func item(_ title: String, on: Bool = false, enabled: Bool = true, _ action: @escaping () -> Void) -> NSMenuItem {
        let i = ClosureMenuItem(title: title, action: action)
        i.state = on ? .on : .off
        i.isEnabled = enabled
        return i
    }

    func fillSpeed(_ m: NSMenu) {
        for s in Self.speeds { m.addItem(item(s == 1 ? "Normal (1×)" : Self.label(s), on: abs(s - speed) < 0.001) { [weak self] in self?.setSpeed(s) }) }
        m.addItem(.separator())
        m.addItem(item("Slower    [") { [weak self] in self?.slower() })
        m.addItem(item("Faster    ]") { [weak self] in self?.faster() })
    }

    func fillAudio(_ m: NSMenu) {
        let names = player.backend?.audioTrackNames ?? []
        guard !names.isEmpty else { m.addItem(item("Only one audio track", enabled: false) {}); return }
        let sel = player.backend?.selectedAudioTrack ?? 0
        for (i, n) in names.enumerated() {
            m.addItem(item(n, on: i == sel) { [weak self] in
                self?.player.backend?.selectAudioTrack(i)
                self?.player.toast.show("Audio: \(n)", symbol: "waveform", sticky: false)
            })
        }
    }

    func fillSubtitles(_ m: NSMenu) {
        m.addItem(item("Off    V", on: subtitleChoice == nil) { [weak self] in self?.selectSubtitle(nil) })
        for (i, c) in subtitleChoices.enumerated() {
            m.addItem(item(c.name, on: subtitleChoice == i) { [weak self] in self?.selectSubtitle(i) })
        }
        if subtitleChoices.isEmpty { m.addItem(item("None found for this video", enabled: false) {}) }
        m.addItem(.separator())
        m.addItem(item("Add Subtitle File…", enabled: player.current != nil) { [weak self] in self?.chooseSubtitleFile() })
    }

    func chooseSubtitleFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = SubtitleReader.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        p.message = "Choose a subtitle file (.srt, .vtt, .ass) for what's playing"
        if let u = player.currentTrack?.url, u.isFileURL { p.directoryURL = u.deletingLastPathComponent() }
        p.beginSheetModal(for: player.window) { r in
            if r == .OK, let u = p.url { self.addSubtitleFile(u) }
        }
    }

    /// The video's right-click: one menu with speed, audio tracks and subtitles.
    func popUpMenu(at screenPoint: NSPoint) {
        let m = NSMenu()
        m.addItem(item("Stop After This Track", on: stopAfterCurrent, enabled: player.current != nil) { [weak self] in self?.toggleStopAfter() })
        m.addItem(.separator())
        m.addItem(Self.header("Speed")); fillSpeed(m)
        if !(player.backend?.audioTrackNames ?? []).isEmpty { m.addItem(.separator()); m.addItem(Self.header("Audio")); fillAudio(m) }
        m.addItem(.separator()); m.addItem(Self.header("Subtitles")); fillSubtitles(m)
        DispatchQueue.main.async { m.popUp(positioning: nil, at: screenPoint, in: nil) }
    }

    private static func header(_ t: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: t) }
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false; return i
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, action: @escaping () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}
