import Foundation
import UniformTypeIdentifiers

enum TrackKind: String, Codable {
    case local      // file on disk
    case remote     // direct media URL (mp4, m3u8, mp3 ...) or a stream (rtsp://, rtmp://, udp:// ...)
    case youtube    // YouTube video id
    case bilibili   // "BVxxxx|cid|page" (or "av123|cid|page")
}

struct Track: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: TrackKind
    /// file URL string, remote URL string, or YouTube video id
    var source: String
    /// Name you assign (triple-click to rename). Wins over autoTitle.
    var customName: String?
    /// Title we discovered (filename, YouTube title, metadata)
    var autoTitle: String
    var loop: Bool = false     // playlists play through; loop a track with L
    /// Struck through: next/previous and auto-advance pass over it, but you can still click it to play.
    /// Optional so libraries saved before this existed still load.
    var skip: Bool? = nil
    var isSkipped: Bool { skip == true }
    /// Local files that aren't on this Mac (e.g. from someone else's playlist) are unavailable.
    var isAvailable: Bool {
        guard kind == .local, let u = url else { return true }
        return FileManager.default.fileExists(atPath: u.path)
    }
    /// Next / previous / auto-advance only land on these.
    var isPlayableInSequence: Bool { !isSkipped && isAvailable }
    var duration: Double?
    /// A live stream (no end, can't seek): found out while it plays, and remembered for the playlist.
    var live: Bool? = nil
    /// This track's own volume, in dB relative to Reel's volume (levels a loud or quiet track against the rest).
    var levelDB: Double? = nil
    var level: Double { levelDB ?? 0 }
    var isLive: Bool { live == true }

    /// A link to a stream rather than a file: live (or possibly live), so never opened twice (no second
    /// connection to look for subtitles), converted or resumed.
    var isStream: Bool {
        guard kind == .remote, let u = url else { return false }
        return isLive || needsInAppDecoder || u.pathExtension.lowercased() == "m3u8"
    }
    /// Played by Reel's own decoder straight away: protocols macOS's player doesn't speak (RTSP, RTMP, UDP,
    /// RTP), DASH, raw MPEG-TS over HTTP (broadcast / IPTV) and MJPEG camera feeds. HLS goes to macOS's
    /// player first (hardware decoding, AirPlay).
    var needsInAppDecoder: Bool {
        guard kind == .remote, let u = url else { return false }
        return MediaResolver.isStreamScheme(u) || ["mpd", "ts", "m2ts", "mts", "mjpg", "mjpeg"].contains(u.pathExtension.lowercased())
    }

    /// True for WebM files/URLs (AVFoundation can't play these; WebKit or an ffmpeg conversion can).
    var isWebM: Bool {
        guard kind == .local || kind == .remote, let u = url else { return false }
        return ["webm", "mkv"].contains(u.pathExtension.lowercased())
    }

    var displayName: String {
        if let n = customName, !n.trimmingCharacters(in: .whitespaces).isEmpty { return n }
        return autoTitle
    }

    var subtitle: String {
        switch kind {
        case .local: return "Local file"
        case .youtube: return "YouTube"
        case .bilibili: return "Bilibili"
        case .remote:
            let u = URL(string: source)
            // (udp://@:1234 listens on a port rather than naming a host)
            let host = u?.host.flatMap { $0.isEmpty ? nil : $0 } ?? u?.port.map { "port \($0)" } ?? "URL"
            let proto = u.flatMap { MediaResolver.isStreamScheme($0) ? $0.scheme?.uppercased() : nil }
            return [isLive ? "● Live" : nil, proto, host].compactMap { $0 }.joined(separator: " · ")
        }
    }

    var url: URL? {
        switch kind {
        case .local, .remote: return URL(string: source)
        case .youtube: return URL(string: "https://www.youtube.com/watch?v=\(source)")
        case .bilibili:
            let parts = source.split(separator: "|").map(String.init)
            let page = parts.count > 2 ? parts[2] : "1"
            return URL(string: "https://www.bilibili.com/video/\(parts.first ?? "")/?p=\(page)")
        }
    }
}

struct Playlist: Codable, Identifiable {
    var id = UUID()
    var name: String
    var tracks: [Track] = []
    /// Opened from a .reel file and not saved: it plays and can be edited, but isn't written to your
    /// playlists (and is gone after you quit) unless you save it.
    var unsaved: Bool? = nil
    var isUnsaved: Bool { unsaved == true }
}

/// Reel's own playlist file: `.reel` (JSON inside). Declared in Info.plist so Finder shows it with Reel's
/// icon and double-clicking opens Reel. Older `.json` exports still import.
extension UTType {
    /// Its own document type (JSON inside, but not declared as JSON/text: Finder would draw the text as the icon).
    static let reelPlaylist = UTType(exportedAs: "app.reel.reel-playlist", conformingTo: .data)
}

/// Reel's playlist file. The export button writes one; dropping one on Reel imports it as a new playlist.
/// Each track is its name, source link, loop and skip — the type is worked out from the link.
/// Reel's own saved playlists (Application Support/Reel/Playlists) are the same files with a little more
/// kept: the playlist's id and place in the list, and each track's full details (ids, titles, length).
struct PlaylistFile: Codable {
    struct Entry: Codable {
        var name: String
        var source: String
        var loop: Bool
        var skip: Bool
        /// The track's own volume (dB), so a levelled album sounds the same for whoever opens it.
        var level: Double? = nil
        /// Full details, in Reel's own saved playlists (ignored when importing someone's playlist).
        var track: Track?
    }
    var format = "reel-playlist"
    var version = 2
    var name: String
    var id: UUID?
    var position: Int?
    var tracks: [Entry]

    init(_ p: Playlist, full: Bool = false, position: Int? = nil) {
        name = p.name
        if full { id = p.id; self.position = position }
        tracks = p.tracks.map { Entry(name: $0.displayName, source: $0.url?.absoluteString ?? $0.source, loop: $0.loop, skip: $0.isSkipped,
                                      level: $0.levelDB, track: full ? $0 : nil) }
    }

    /// Reads the current format, or the earlier one that stored whole tracks.
    static func read(_ url: URL) -> [Track]? {
        readNamed(url)?.1
    }
    static func readNamed(_ url: URL) -> (String, [Track])? {
        guard ["reel", "json"].contains(url.pathExtension.lowercased()), let data = try? Data(contentsOf: url) else { return nil }
        if let f = try? JSONDecoder().decode(PlaylistFile.self, from: data), f.format == "reel-playlist" {
            return (f.name, f.tracks.compactMap { e in
                if let t = e.track { return t }
                guard var t = MediaResolver.track(fromSource: e.source, name: e.name) else { return nil }
                t.loop = e.loop
                t.skip = e.skip ? true : nil
                t.levelDB = e.level.map(TrackLevel.clamp).flatMap { $0 == 0 ? nil : $0 }
                return t
            })
        }
        struct Legacy: Codable { var format: String; var name: String; var tracks: [Track] }
        if let f = try? JSONDecoder().decode(Legacy.self, from: data), f.format == "reel-playlist" { return (f.name, f.tracks) }
        return nil
    }

    /// One of Reel's saved playlists: the playlist (same id as before) and its place in the list.
    static func readSaved(_ url: URL) -> (Playlist, Int?)? {
        guard let data = try? Data(contentsOf: url),
              let f = try? JSONDecoder().decode(PlaylistFile.self, from: data), f.format == "reel-playlist",
              let (name, tracks) = readNamed(url) else { return nil }
        return (Playlist(id: f.id ?? UUID(), name: name, tracks: tracks), f.position)
    }

    func encoded() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(self)) ?? Data()
    }
}

/// Holds every playlist. Each one is saved as its own .reel file in
/// ~/Library/Application Support/Reel/Playlists — the same format Export writes, so you can copy them,
/// back them up or share them. (Older versions kept everything in library.json; that's converted once
/// and left where it was as a backup.)
final class Library {
    static let shared = Library()
    static let changed = Notification.Name("ReelLibraryChanged")

    private(set) var playlists: [Playlist] = []
    /// Whether a saved library was already on disk when Reel started (i.e. not a fresh install).
    private(set) var existedAtLaunch = false
    private var saveWork: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "reel.library.save")

    /// REEL_LIBRARY: a folder of .reel files to use instead, or a .json file in the old single-file format (tests).
    private enum Store { case folder(URL), legacy(URL) }
    private static let store: Store = {
        if let o = ProcessInfo.processInfo.environment["REEL_LIBRARY"] {
            return o.lowercased().hasSuffix(".json") ? .legacy(URL(fileURLWithPath: o)) : .folder(URL(fileURLWithPath: o, isDirectory: true))
        }
        return .folder(supportDir.appendingPathComponent("Playlists", isDirectory: true))
    }()
    private static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Reel", isDirectory: true)
    }
    /// Where the playlists are saved (nil when testing with a single file).
    static var folder: URL? { if case .folder(let d) = store { return d } else { return nil } }

    /// File names (lowercased) Reel wrote or loaded in the folder — the only ones it ever deletes or replaces.
    private var owned = Set<String>()
    /// Each playlist's file name from the last save, for "Show in Finder".
    private var fileNames: [UUID: String] = [:]
    /// Unsaved playlists and the .reel file each was opened from (opening it again reuses it).
    private var openedFrom: [UUID: URL] = [:]

    private init() {
        let fm = FileManager.default
        var migrate = false
        switch Self.store {
        case .legacy(let url):
            existedAtLaunch = fm.fileExists(atPath: url.path)
            if let data = try? Data(contentsOf: url), let lists = try? JSONDecoder().decode([Playlist].self, from: data) { playlists = lists }
        case .folder(let dir):
            if fm.fileExists(atPath: dir.path) {
                existedAtLaunch = true
                var loaded: [(Playlist, Int?, String)] = []
                var ids = Set<UUID>()
                let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                for f in files where f.pathExtension.lowercased() == "reel" {
                    guard var (p, pos) = PlaylistFile.readSaved(f) else { continue }
                    if !ids.insert(p.id).inserted { p.id = UUID() }          // a copied file: give it its own identity
                    loaded.append((p, pos, f.lastPathComponent))
                    owned.insert(f.lastPathComponent.lowercased())
                }
                loaded.sort { ($0.1 ?? Int.max, $0.0.name.lowercased()) < ($1.1 ?? Int.max, $1.0.name.lowercased()) }
                playlists = loaded.map(\.0)
                for (p, _, name) in loaded { fileNames[p.id] = name }
            } else if Self.folder == Self.supportDir.appendingPathComponent("Playlists", isDirectory: true) {
                let old = Self.supportDir.appendingPathComponent("library.json")
                if let data = try? Data(contentsOf: old), let lists = try? JSONDecoder().decode([Playlist].self, from: data) {
                    playlists = lists; existedAtLaunch = true; migrate = true
                }
            }
        }
        if playlists.isEmpty { playlists = [Playlist(name: "Playlist 1")] }
        if migrate { saveNow() }
    }

    func index(of id: UUID) -> Int? { playlists.firstIndex { $0.id == id } }
    func playlist(_ id: UUID) -> Playlist? { index(of: id).map { playlists[$0] } }

    /// The saved .reel file for this playlist, if it has been written.
    func fileURL(for id: UUID) -> URL? {
        guard let dir = Self.folder, let name = fileNames[id] else { return nil }
        return dir.appendingPathComponent(name)
    }

    func mutate(_ id: UUID, _ body: (inout Playlist) -> Void) {
        guard let i = index(of: id) else { return }
        body(&playlists[i])
        didChange()
    }

    func mutateTrack(_ trackID: UUID, _ body: (inout Track) -> Void) {
        for p in playlists.indices {
            if let t = playlists[p].tracks.firstIndex(where: { $0.id == trackID }) {
                body(&playlists[p].tracks[t])
            }
        }
        didChange()
    }

    @discardableResult
    func addPlaylist(named name: String) -> Playlist {
        let p = Playlist(name: name)
        playlists.append(p)
        didChange()
        return p
    }

    /// Moves playlists (by their current positions) to sit before `row` — the playlists list's drag to reorder.
    func movePlaylists(_ rows: [Int], to row: Int) {
        let rows = rows.filter { $0 < playlists.count }.sorted()
        let moving = rows.map { playlists[$0] }
        let before = rows.filter { $0 < row }.count
        for r in rows.reversed() { playlists.remove(at: r) }
        playlists.insert(contentsOf: moving, at: min(max(0, row - before), playlists.count))
        didChange()
    }

    /// A .reel file opened from Finder (or dropped on the video): if it's one of your saved playlists, that
    /// playlist; if it's already open, that one; otherwise a new *unsaved* playlist that isn't kept unless you save it.
    func open(file url: URL) -> Playlist? {
        let u = url.standardizedFileURL.resolvingSymlinksInPath()
        if let dir = Self.folder, u.deletingLastPathComponent().path == dir.standardizedFileURL.resolvingSymlinksInPath().path,
           let id = fileNames.first(where: { $0.value.lowercased() == u.lastPathComponent.lowercased() })?.key, let p = playlist(id) {
            return p
        }
        if let id = openedFrom.first(where: { $0.value == u })?.key, let p = playlist(id) { return p }
        guard let (name, tracks) = PlaylistFile.readNamed(url) else { return nil }
        var p = Playlist(name: name)
        p.tracks = tracks.map { var t = $0; t.id = UUID(); return t }
        p.unsaved = true
        playlists.append(p)
        openedFrom[p.id] = u
        didChange()
        return p
    }

    /// A playlist to play without saving (a YouTube playlist you chose to just play).
    func openUnsaved(named name: String, tracks: [Track]) -> Playlist {
        var p = Playlist(name: name)
        p.tracks = tracks
        p.unsaved = true
        playlists.append(p)
        didChange()
        return p
    }

    /// Keeps an unsaved playlist: it's written to your playlists from now on (name made unique among them).
    func save(_ id: UUID) {
        guard let p = playlist(id), p.isUnsaved else { return }
        var name = p.name, n = 2
        while playlists.contains(where: { $0.id != id && !$0.isUnsaved && $0.name.lowercased() == name.lowercased() }) { name = "\(p.name) \(n)"; n += 1 }
        openedFrom[id] = nil
        mutate(id) { $0.unsaved = nil; $0.name = name }
    }

    /// Adds an exported playlist as a new one (fresh ids, name made unique).
    func importPlaylist(named base: String, tracks: [Track]) -> Playlist {
        var name = base, n = 2
        while playlists.contains(where: { !$0.isUnsaved && $0.name == name }) { name = "\(base) \(n)"; n += 1 }   // only your saved ones count
        var p = Playlist(name: name)
        p.tracks = tracks.map { var t = $0; t.id = UUID(); return t }
        playlists.append(p)
        didChange()
        return p
    }

    func removePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        openedFrom[id] = nil
        if !playlists.contains(where: { !$0.isUnsaved }) { playlists.insert(Playlist(name: "Playlist 1"), at: 0) }
        didChange()
    }

    func nextPlaylistName() -> String {
        var n = playlists.count + 1
        while playlists.contains(where: { $0.name == "Playlist \(n)" }) { n += 1 }
        return "Playlist \(n)"
    }

    private func didChange() {
        NotificationCenter.default.post(name: Library.changed, object: self)
        saveWork?.cancel()
        let job = saveJob()
        let work = DispatchWorkItem { job() }
        saveWork = work
        saveQueue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        let job = saveJob()
        saveQueue.sync { job() }
    }

    /// Works out what to write (on the main thread), returns the disk work to do.
    private func saveJob() -> () -> Void {
        switch Self.store {
        case .legacy(let url):
            let data = (try? JSONEncoder().encode(playlists.filter { !$0.isUnsaved })) ?? Data()
            return { try? data.write(to: url, options: .atomic) }
        case .folder(let dir):
            var used = Set<String>(), writes: [(String, Data)] = []
            for (i, p) in playlists.filter({ !$0.isUnsaved }).enumerated() {
                var base = p.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                while base.hasPrefix(".") { base.removeFirst() }
                if base.isEmpty { base = "Playlist" }
                var name = base + ".reel", n = 2
                while used.contains(name.lowercased()) { name = "\(base) \(n).reel"; n += 1 }
                used.insert(name.lowercased())
                fileNames[p.id] = name
                writes.append((name, PlaylistFile(p, full: true, position: i).encoded()))
            }
            // Renamed or deleted playlists' old files. `owned` only grows, so a save that's replaced by a newer one
            // before it runs doesn't lose track of what needs removing.
            owned.formUnion(used)
            let stale = owned.subtracting(used)
            return {
                let fm = FileManager.default
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                for (name, data) in writes {
                    let url = dir.appendingPathComponent(name)
                    if (try? Data(contentsOf: url)) != data { try? data.write(to: url, options: .atomic) }
                }
                let present = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                for f in present where stale.contains(f.lastPathComponent.lowercased()) && !used.contains(f.lastPathComponent.lowercased()) {
                    try? fm.removeItem(at: f)
                }
            }
        }
    }
}

/// Hearing is logarithmic, so the volume percentage is a position on a decibel scale, not an
/// amplitude: 100% = 0 dB, every step down is the same number of dB quieter, 0% = silent.
enum Loudness {
    /// Quietest audible level (just above 0%) sits this far below full volume.
    static let rangeDB: Float = 45
    /// Below this level the curve fades linearly to true silence instead of jumping to it.
    private static let taper: Float = 0.05

    /// Level (0…1, what the % shows) → amplitude gain for the player (0…1).
    static func gain(_ level: Float) -> Float {
        let p = max(0, min(1, level))
        guard p > 0 else { return 0 }
        let g = powf(10, (p - 1) * rangeDB / 20)
        return p < taper ? g * (p / taper) : g
    }

    /// Inverse of `gain` (used once to convert an old saved volume).
    static func level(forGain g: Float) -> Float {
        guard g > 0 else { return 0 }
        return max(taper, min(1, 1 + 20 * log10f(min(1, g)) / rangeDB))
    }
}

enum Prefs {
    static var alwaysOnTop: Bool {
        get { UserDefaults.standard.object(forKey: "alwaysOnTop") as? Bool ?? true }   // on unless you turn it off
        set { UserDefaults.standard.set(newValue, forKey: "alwaysOnTop") }
    }
    /// The volume *level* you see as a percentage (0…1, perceptual — see `Loudness`).
    /// Older versions stored the raw gain under "volume"; that's converted so it sounds the same.
    /// Reel's hotkeys while the mouse is over it, even when another app is active. Off by default, but
    /// allowing Reel in Privacy & Security → Accessibility counts as turning it on (until you switch it off).
    static var hoverHotkeys: Bool {
        get { UserDefaults.standard.object(forKey: "hoverHotkeys") as? Bool ?? HoverHotkeys.isTrusted }
        set { UserDefaults.standard.set(newValue, forKey: "hoverHotkeys") }
    }
    static var volume: Float {
        get {
            if let v = UserDefaults.standard.object(forKey: "volumeLevel") as? Float { return v }
            if let g = UserDefaults.standard.object(forKey: "volume") as? Float { return Loudness.level(forGain: g) }
            return 1.0
        }
        set { UserDefaults.standard.set(newValue, forKey: "volumeLevel") }
    }
    /// Shuffle the playlist's order (S). Kept between launches.
    static var shuffle: Bool {
        get { UserDefaults.standard.bool(forKey: "shuffle") }
        set { UserDefaults.standard.set(newValue, forKey: "shuffle") }
    }
    static var lastPlaylist: String? {
        get { UserDefaults.standard.string(forKey: "lastPlaylist") }
        set { UserDefaults.standard.set(newValue, forKey: "lastPlaylist") }
    }
}
