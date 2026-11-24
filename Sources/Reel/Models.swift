import Foundation

enum TrackKind: String, Codable {
    case local      // file on disk
    case remote     // direct media URL (mp4, m3u8, mp3 ...)
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
    var loop: Bool = true      // new tracks loop by default
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
        case .remote: return URL(string: source)?.host ?? "URL"
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
}

/// What the export button writes; dropping one of these on Reel imports it as a new playlist.
/// Each track is just its name, source link, loop and skip — the type is worked out from the link.
struct PlaylistFile: Codable {
    struct Entry: Codable {
        var name: String
        var source: String
        var loop: Bool
        var skip: Bool
    }
    var format = "reel-playlist"
    var version = 2
    var name: String
    var tracks: [Entry]

    init(_ p: Playlist) {
        name = p.name
        tracks = p.tracks.map { Entry(name: $0.displayName, source: $0.url?.absoluteString ?? $0.source, loop: $0.loop, skip: $0.isSkipped) }
    }

    /// Reads the current format, or the earlier one that stored whole tracks.
    static func read(_ url: URL) -> [Track]? {
        readNamed(url)?.1
    }
    static func readNamed(_ url: URL) -> (String, [Track])? {
        guard url.pathExtension.lowercased() == "json", let data = try? Data(contentsOf: url) else { return nil }
        if let f = try? JSONDecoder().decode(PlaylistFile.self, from: data), f.format == "reel-playlist" {
            return (f.name, f.tracks.compactMap { e in
                guard var t = MediaResolver.track(fromSource: e.source, name: e.name) else { return nil }
                t.loop = e.loop
                t.skip = e.skip ? true : nil
                return t
            })
        }
        struct Legacy: Codable { var format: String; var name: String; var tracks: [Track] }
        if let f = try? JSONDecoder().decode(Legacy.self, from: data), f.format == "reel-playlist" { return (f.name, f.tracks) }
        return nil
    }
}

/// Holds every playlist and saves to ~/Library/Application Support/Reel/library.json
final class Library {
    static let shared = Library()
    static let changed = Notification.Name("ReelLibraryChanged")

    private(set) var playlists: [Playlist] = []
    /// Whether a saved library was already on disk when Reel started (i.e. not a fresh install).
    private(set) var existedAtLaunch = false
    private var saveWork: DispatchWorkItem?

    private var fileURL: URL {
        if let override = ProcessInfo.processInfo.environment["REEL_LIBRARY"] { return URL(fileURLWithPath: override) }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Reel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.json")
    }

    private init() {
        existedAtLaunch = FileManager.default.fileExists(atPath: fileURL.path)
        if let data = try? Data(contentsOf: fileURL),
           let lists = try? JSONDecoder().decode([Playlist].self, from: data), !lists.isEmpty {
            playlists = lists
        } else {
            playlists = [Playlist(name: "Playlist 1")]
        }
    }

    func index(of id: UUID) -> Int? { playlists.firstIndex { $0.id == id } }
    func playlist(_ id: UUID) -> Playlist? { index(of: id).map { playlists[$0] } }

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

    /// Adds an exported playlist as a new one (fresh ids, name made unique).
    func importPlaylist(named base: String, tracks: [Track]) -> Playlist {
        var name = base, n = 2
        while playlists.contains(where: { $0.name == name }) { name = "\(base) \(n)"; n += 1 }
        var p = Playlist(name: name)
        p.tracks = tracks.map { var t = $0; t.id = UUID(); return t }
        playlists.append(p)
        didChange()
        return p
    }

    func removePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        if playlists.isEmpty { playlists = [Playlist(name: "Playlist 1")] }
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
        let snapshot = playlists
        let url = fileURL
        let work = DispatchWorkItem {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        if let data = try? JSONEncoder().encode(playlists) { try? data.write(to: fileURL, options: .atomic) }
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
    /// Reel's hotkeys while the mouse is over it, even when another app is active (off by default).
    static var hoverHotkeys: Bool {
        get { UserDefaults.standard.bool(forKey: "hoverHotkeys") }
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
    static var lastPlaylist: String? {
        get { UserDefaults.standard.string(forKey: "lastPlaylist") }
        set { UserDefaults.standard.set(newValue, forKey: "lastPlaylist") }
    }
}
