import Foundation
import UniformTypeIdentifiers

/// Turns pasted text, URLs and dropped files into Tracks.
enum MediaResolver {

    // MARK: Entry points

    static func tracks(forFiles urls: [URL]) -> [Track] {
        var out: [Track] = []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                let files = (FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                                           options: [.skipsHiddenFiles])?.allObjects as? [URL]) ?? []
                for f in files.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
                where isMedia(f) {
                    out.append(localTrack(f))
                }
            } else if url.isFileURL {
                out.append(localTrack(url))
            }
        }
        return out
    }

    /// Parses any text (one or more URLs, separated by whitespace/newlines) into tracks.
    static func tracks(forText text: String) async -> [Track] {
        var out: [Track] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if line.isEmpty { continue }
            // A whole line that is a local path (spaces allowed) or file:// URL
            if let u = URL(string: line), u.isFileURL { out += tracks(forFiles: [u]); continue }
            if line.hasPrefix("/") || line.hasPrefix("~") {
                let path = (line as NSString).expandingTildeInPath
                if FileManager.default.fileExists(atPath: path) { out += tracks(forFiles: [URL(fileURLWithPath: path)]); continue }
            }
            // Otherwise: one or more web URLs separated by spaces
            for p in line.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
                if let u = URL(string: p), u.isFileURL {
                    out += tracks(forFiles: [u])
                } else if let u = normalizedURL(p) {
                    out += await tracks(forURL: u)
                }
            }
        }
        return out
    }

    /// How many things `tracks(forText:)` would look up — no network, so it's quick enough to
    /// run while something is being dragged. 0 means nothing in the text is addable.
    static func linkCount(in text: String) -> Int {
        var n = 0
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if line.isEmpty { continue }
            if let u = URL(string: line), u.isFileURL { n += 1; continue }
            if line.hasPrefix("/") || line.hasPrefix("~"),
               FileManager.default.fileExists(atPath: (line as NSString).expandingTildeInPath) { n += 1; continue }
            for p in line.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
                if URL(string: p)?.isFileURL == true || normalizedURL(p) != nil { n += 1 }
            }
        }
        return n
    }

    static func tracks(forURL url: URL) async -> [Track] {
        if url.isFileURL { return tracks(forFiles: [url]) }
        if isBilibili(url) { return await bilibiliTracks(url) }
        if let yt = parseYouTube(url) {
            if let list = yt.list {
                let items = await youtubePlaylist(list: list, videoID: yt.video)
                if !items.isEmpty { return items }
            }
            if let vid = yt.video {
                let title = await youtubeTitle(vid) ?? "YouTube \(vid)"
                return [Track(kind: .youtube, source: vid, autoTitle: title)]
            }
            return []
        }
        let name = url.deletingPathExtension().lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        return [Track(kind: .remote, source: url.absoluteString,
                      autoTitle: name.isEmpty ? (url.host ?? url.absoluteString) : name)]
    }

    // MARK: Helpers

    static func isMedia(_ url: URL) -> Bool {
        if ["webm", "mkv"].contains(url.pathExtension.lowercased()) { return true }
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return t.conforms(to: .audiovisualContent)
    }

    private static func localTrack(_ url: URL) -> Track {
        Track(kind: .local, source: url.absoluteString, autoTitle: url.deletingPathExtension().lastPathComponent)
    }

    /// Accepts http(s) URLs, plus bare links for the sites we know (youtube.com/…, b23.tv/…, www.…)
    /// so ordinary words in copied text never turn into bogus entries.
    static func normalizedURL(_ s: String) -> URL? {
        var str = s.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'()[],;"))
        if !str.contains("://") {
            let lower = str.lowercased()
            let known = ["www.", "youtube.com/", "m.youtube.com/", "music.youtube.com/", "youtu.be/",
                         "bilibili.com/", "m.bilibili.com/", "b23.tv/"]
            guard known.contains(where: { lower.hasPrefix($0) }) else { return nil }
            str = "https://" + str
        }
        guard let u = URL(string: str), let scheme = u.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = u.host, host.contains(".") else { return nil }
        return u
    }

    /// Rebuilds a track from an exported source link (no network needed).
    static func track(fromSource src: String, name: String) -> Track? {
        if src.hasPrefix("/") || src.hasPrefix("~") {
            let u = URL(fileURLWithPath: (src as NSString).expandingTildeInPath)
            return Track(kind: .local, source: u.absoluteString, autoTitle: name)
        }
        guard let u = URL(string: src) else { return nil }
        if u.isFileURL { return Track(kind: .local, source: u.absoluteString, autoTitle: name) }
        if let yt = parseYouTube(u), let v = yt.video { return Track(kind: .youtube, source: v, autoTitle: name) }
        if isBilibili(u), let m = u.path.firstMatch(of: #/(BV[0-9A-Za-z]{10})/#) {
            let page = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "p" }?.value ?? "1"
            return Track(kind: .bilibili, source: "\(m.1)|0|\(page)", autoTitle: name)   // part id looked up when played
        }
        guard let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        return Track(kind: .remote, source: u.absoluteString, autoTitle: name)
    }

    // MARK: Bilibili

    static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static func isBilibili(_ url: URL) -> Bool {
        guard let h = url.host?.lowercased() else { return false }
        return h == "b23.tv" || h.hasSuffix("bilibili.com")
    }

    static func bilibiliTracks(_ url: URL) async -> [Track] {
        var url = url
        if url.host?.lowercased() == "b23.tv" {   // short link → follow the redirect
            var req = URLRequest(url: url); req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
            if let (_, resp) = try? await URLSession.shared.data(for: req), let final = resp.url { url = final }
        }
        let path = url.path
        var id: String?
        if let m = path.firstMatch(of: #/(BV[0-9A-Za-z]{10})/#) { id = String(m.1) }
        else if let m = path.lowercased().firstMatch(of: #/av(\d+)/#) { id = "av" + String(m.1) }
        guard let vid = id else { return [] }
        let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "p" }?.value.flatMap(Int.init)

        let q = vid.hasPrefix("BV") ? "bvid=\(vid)" : "aid=\(vid.dropFirst(2))"
        var req = URLRequest(url: URL(string: "https://api.bilibili.com/x/player/pagelist?\(q)")!)
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = obj["data"] as? [[String: Any]], !pages.isEmpty else { return [] }
        return pages.compactMap { p -> Track? in
            guard let cid = p["cid"] as? Int else { return nil }
            let n = p["page"] as? Int ?? 1
            if let page, page != n { return nil }
            var title = (p["part"] as? String) ?? vid
            if pages.count > 1 { title = "P\(n) · " + title }
            var t = Track(kind: .bilibili, source: "\(vid)|\(cid)|\(n)", autoTitle: title)
            t.duration = (p["duration"] as? Double) ?? (p["duration"] as? Int).map(Double.init)
            return t
        }
    }

    /// Fresh stream URL for a Bilibili track (they expire, so this runs at play time).
    static func bilibiliStream(_ source: String) async -> URL? {
        var parts = source.split(separator: "|").map(String.init)
        guard parts.count >= 2 else { return nil }
        let idParam = parts[0].hasPrefix("BV") ? "bvid=\(parts[0])" : "avid=\(parts[0].dropFirst(2))"
        if parts[1] == "0" {   // imported link: find the part's id first
            let page = parts.count > 2 ? parts[2] : "1"
            let ps = await bilibiliTracks(URL(string: "https://www.bilibili.com/video/\(parts[0])/?p=\(page)")!)
            guard let found = ps.first?.source.split(separator: "|").map(String.init), found.count >= 2 else { return nil }
            parts[1] = found[1]
        }
        let u = "https://api.bilibili.com/x/player/playurl?\(idParam)&cid=\(parts[1])&qn=80&fnval=1&platform=html5&high_quality=1"
        var req = URLRequest(url: URL(string: u)!)
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let d = obj["data"] as? [String: Any],
              let durl = d["durl"] as? [[String: Any]], let s = durl.first?["url"] as? String else { return nil }
        return URL(string: s)
    }

    // MARK: Transparent WebM

    static func findFFmpeg() -> String? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// WebM files with an alpha channel carry Matroska "AlphaMode = 1" (EBML 53 C0 81 01) in the header.
    static func webmHasAlpha(_ url: URL) async -> Bool {
        var head = Data()
        if url.isFileURL {
            guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
            head = (try? fh.read(upToCount: 262_144)) ?? Data()
            try? fh.close()
        } else {
            var req = URLRequest(url: url)
            req.setValue("bytes=0-262143", forHTTPHeaderField: "Range")
            req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
            head = (try? await URLSession.shared.data(for: req).0) ?? Data()
        }
        return head.range(of: Data([0x53, 0xC0, 0x81, 0x01])) != nil
    }

    /// Converts a transparent WebM to HEVC-with-alpha (which macOS plays with real transparency). Cached.
    static func alphaMovie(for url: URL, progress: (@Sendable (Double) -> Void)? = nil) async -> URL? {
        await convertedMovie(for: url, keepAlpha: true, progress: progress)
    }

    /// Converts something macOS can't decode into HEVC it always can (cached). `keepAlpha` is for
    /// transparent WebM; otherwise it's a plain conversion (e.g. VP9 variants Apple's decoder rejects).
    static func convertedMovie(for url: URL, keepAlpha: Bool, progress: (@Sendable (Double) -> Void)? = nil) async -> URL? {
        guard let ffmpeg = findFFmpeg() else { return nil }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(keepAlpha ? "Reel/alpha" : "Reel/converted", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var key = url.absoluteString
        if url.isFileURL, let a = try? FileManager.default.attributesOfItem(atPath: url.path) {
            key += "|\((a[.size] as? Int) ?? 0)|\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        }
        let hash = String(format: "%016llx", key.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 })
        let out = dir.appendingPathComponent(hash + ".mov")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let tmp = dir.appendingPathComponent(hash + ".part.mov")
        let input = url.isFileURL ? url.path : url.absoluteString
        let ok: Bool = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                // Length, for the progress percentage.
                var duration = 0.0
                let probe = ffmpeg.replacingOccurrences(of: "/ffmpeg", with: "/ffprobe")
                if FileManager.default.isExecutableFile(atPath: probe) {
                    let q = Process(); let o = Pipe()
                    q.executableURL = URL(fileURLWithPath: probe)
                    q.arguments = ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", input]
                    q.standardOutput = o; q.standardError = FileHandle.nullDevice
                    if (try? q.run()) != nil {
                        let d = o.fileHandleForReading.readDataToEndOfFile(); q.waitUntilExit()
                        duration = Double(String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
                    }
                }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: ffmpeg)
                var args = ["-loglevel", "error", "-nostats", "-progress", "pipe:1", "-y", "-threads", "0"]
                if !url.isFileURL { args += ["-user_agent", browserUA] }
                // libvpx (not ffmpeg's native vp9 decoder) is what actually decodes the alpha plane.
                // The software VP9-with-alpha decode is the slow part; the hardware encoder runs in
                // speed-priority mode (~1.8× faster than default).
                if keepAlpha { args += ["-c:v", "libvpx-vp9"] }
                args += ["-i", input]
                let video = keepAlpha
                    ? ["-c:v", "hevc_videotoolbox", "-alpha_quality", "0.9", "-tag:v", "hvc1", "-q:v", "70"]
                    : ["-c:v", "hevc_videotoolbox", "-tag:v", "hvc1", "-q:v", "65"]
                p.arguments = args + video + ["-realtime", "1", "-prio_speed", "1", "-c:a", "aac", tmp.path]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                if duration > 0, let progress {
                    out.fileHandleForReading.readabilityHandler = { h in
                        guard let text = String(data: h.availableData, encoding: .utf8) else { return }
                        for line in text.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                            if let us = Double(line.dropFirst(12)) { progress(min(1, us / 1_000_000 / duration)) }
                        }
                    }
                }
                do { try p.run() } catch { cont.resume(returning: false); return }
                p.waitUntilExit()
                out.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: p.terminationStatus == 0)
            }
        }
        guard ok else { try? FileManager.default.removeItem(at: tmp); return nil }
        try? FileManager.default.moveItem(at: tmp, to: out)
        return out
    }

    // MARK: YouTube

    /// YouTube links in some text that point at a playlist (watch?v=…&list=… or playlist?list=…).
    static func youtubePlaylistLinks(in text: String) -> [(link: String, video: String?, list: String)] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).compactMap { tok in
            let str = String(tok)
            guard let u = normalizedURL(str), let yt = parseYouTube(u), let list = yt.list else { return nil }
            return (str, yt.video, list)
        }
    }

    /// The playlist's title, for naming a new Reel playlist after it.
    static func youtubePlaylistTitle(_ list: String) async -> String? {
        guard let data = await get(URL(string: "https://www.youtube.com/playlist?list=\(list)&hl=en")!),
              let html = String(data: data, encoding: .utf8) else { return nil }
        if let m = html.firstMatch(of: #/<meta property="og:title" content="([^"]+)"/#) {
            let t = String(m.1).replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&quot;", with: "\"")
            if !t.isEmpty { return t }
        }
        if let m = html.firstMatch(of: #/<title>(.*?)( - YouTube)?</title>/#) {
            let t = String(m.1); if !t.isEmpty && t != "YouTube" { return t }
        }
        return list.hasPrefix("RD") ? "YouTube Mix" : nil
    }

    struct YouTubeRef { var video: String?; var list: String? }

    static func parseYouTube(_ url: URL) -> YouTubeRef? {
        guard let host = url.host?.lowercased() else { return nil }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        func q(_ name: String) -> String? { comps?.queryItems?.first { $0.name == name }?.value }
        let path = url.pathComponents.filter { $0 != "/" }

        if host == "youtu.be" {
            return YouTubeRef(video: path.first, list: q("list"))
        }
        guard host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com") else { return nil }
        var video = q("v")
        if video == nil, path.count >= 2, ["shorts", "embed", "live", "v"].contains(path[0]) { video = path[1] }
        let list = q("list")
        if video == nil && list == nil { return nil }
        return YouTubeRef(video: video, list: list)
    }

    private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private static func get(_ url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("SOCS=CAI; CONSENT=YES+1", forHTTPHeaderField: "Cookie")
        return try? await URLSession.shared.data(for: req).0
    }

    static func youtubeTitle(_ id: String) async -> String? {
        let target = "https://www.youtube.com/watch?v=\(id)"
        var c = URLComponents(string: "https://www.youtube.com/oembed")!
        c.queryItems = [URLQueryItem(name: "url", value: target), URLQueryItem(name: "format", value: "json")]
        guard let data = await get(c.url!),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["title"] as? String
    }

    /// Expand a playlist. Uses yt-dlp if you have it, otherwise reads YouTube's page data directly.
    static func youtubePlaylist(list: String, videoID: String?) async -> [Track] {
        if let ytdlp = findYtDlp() {
            let items = await ytdlpPlaylist(ytdlp, list: list)
            if !items.isEmpty { return items }
        }
        var items = await scrapePlaylistPage(list: list)
        if items.isEmpty, let v = videoID {
            // Mixes ("RD…") and some auto lists only exist on the watch page
            items = await scrapeWatchPanel(video: v, list: list)
        }
        return items
    }

    static func findYtDlp() -> String? {
        ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp", NSHomeDirectory() + "/.local/bin/yt-dlp"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func ytdlpPlaylist(_ bin: String, list: String) async -> [Track] {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: bin)
                p.arguments = ["--flat-playlist", "-J", "https://www.youtube.com/playlist?list=\(list)"]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(returning: []); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let entries = obj["entries"] as? [[String: Any]] else { cont.resume(returning: []); return }
                let tracks = entries.compactMap { e -> Track? in
                    guard let id = e["id"] as? String else { return nil }
                    var t = Track(kind: .youtube, source: id, autoTitle: (e["title"] as? String) ?? id)
                    t.duration = e["duration"] as? Double
                    return t
                }
                cont.resume(returning: tracks)
            }
        }
    }

    private static func extractJSON(after marker: String, in html: String) -> Any? {
        guard let r = html.range(of: marker) else { return nil }
        // Walk braces to find the end of the object
        let s = html[r.upperBound...]
        guard let start = s.firstIndex(of: "{") else { return nil }
        var depth = 0, inStr = false, esc = false
        var idx = start
        while idx < s.endIndex {
            let ch = s[idx]
            if inStr {
                if esc { esc = false } else if ch == "\\" { esc = true } else if ch == "\"" { inStr = false }
            } else {
                if ch == "\"" { inStr = true }
                else if ch == "{" { depth += 1 }
                else if ch == "}" { depth -= 1; if depth == 0 { break } }
            }
            idx = s.index(after: idx)
        }
        guard idx < s.endIndex else { return nil }
        let json = String(s[start...idx])
        return try? JSONSerialization.jsonObject(with: Data(json.utf8))
    }

    /// Like walk, but also reports whether we're inside the playlist's own item list.
    private static func walkScoped(_ node: Any, inList: Bool = false, _ visit: (String, [String: Any], Bool) -> Void) {
        let listKeys: Set<String> = ["itemSectionRenderer", "appendContinuationItemsAction", "playlistVideoListRenderer",
                                     "playlistPanelRenderer", "reloadContinuationItemsCommand"]
        if let d = node as? [String: Any] {
            for (k, v) in d {
                let scoped = inList || listKeys.contains(k)
                if let vd = v as? [String: Any] { visit(k, vd, scoped) }
                walkScoped(v, inList: scoped, visit)
            }
        } else if let a = node as? [Any] {
            for v in a { walkScoped(v, inList: inList, visit) }
        }
    }

    private static func walk(_ node: Any, _ visit: (String, [String: Any]) -> Void) {
        if let d = node as? [String: Any] {
            for (k, v) in d {
                if let vd = v as? [String: Any] { visit(k, vd) }
                walk(v, visit)
            }
        } else if let a = node as? [Any] {
            for v in a { walk(v, visit) }
        }
    }

    private static func text(_ obj: Any?) -> String? {
        guard let d = obj as? [String: Any] else { return nil }
        if let s = d["simpleText"] as? String { return s }
        if let runs = d["runs"] as? [[String: Any]] { return runs.compactMap { $0["text"] as? String }.joined() }
        return nil
    }

    private static func parseClock(_ s: String) -> Double? {
        let parts = s.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, parts.count == s.split(separator: ":").count else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// Collects videos from both the classic renderers and the newer "lockupViewModel" layout.
    private static func collect(_ root: Any, rendererKey: String, lockups: Bool,
                                into tracks: inout [Track], seen: inout Set<String>) -> String? {
        var token: String?
        walkScoped(root) { key, d, inList in
            if key == rendererKey, let id = d["videoId"] as? String, !seen.contains(id) {
                seen.insert(id)
                var t = Track(kind: .youtube, source: id, autoTitle: text(d["title"]) ?? id)
                if let secs = d["lengthSeconds"] as? String { t.duration = Double(secs) }
                else if let l = text(d["lengthText"]) { t.duration = parseClock(l) }
                tracks.append(t)
            }
            if lockups, inList, key == "lockupViewModel", (d["contentType"] as? String) == "LOCKUP_CONTENT_TYPE_VIDEO",
               let id = d["contentId"] as? String, !seen.contains(id) {
                seen.insert(id)
                let meta = (d["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any]
                let title = ((meta?["title"] as? [String: Any])?["content"] as? String) ?? id
                var t = Track(kind: .youtube, source: id, autoTitle: title)
                walk(d["contentImage"] ?? [:]) { k, b in
                    if t.duration == nil, k == "thumbnailBadgeViewModel", let txt = b["text"] as? String { t.duration = parseClock(txt) }
                }
                tracks.append(t)
            }
            if inList, key == "continuationCommand", let tok = d["token"] as? String { token = tok }
        }
        return token
    }

    private static func scrapePlaylistPage(list: String) async -> [Track] {
        guard let data = await get(URL(string: "https://www.youtube.com/playlist?list=\(list)&hl=en")!),
              let html = String(data: data, encoding: .utf8),
              let initial = extractJSON(after: "ytInitialData = ", in: html) ?? extractJSON(after: "ytInitialData\"] = ", in: html)
        else { return [] }

        var tracks: [Track] = []
        var seen = Set<String>()
        var token = collect(initial, rendererKey: "playlistVideoRenderer", lockups: true, into: &tracks, seen: &seen)

        let version = html.firstMatch(of: #/"INNERTUBE_CLIENT_VERSION":"([^"]+)"/#).map { String($0.1) } ?? "2.20250101.00.00"
        var pages = 0
        while let tok = token, pages < 60 {
            pages += 1
            var req = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
            let body: [String: Any] = [
                "context": ["client": ["clientName": "WEB", "clientVersion": version, "hl": "en"]],
                "continuation": tok,
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            guard let (d, _) = try? await URLSession.shared.data(for: req),
                  let obj = try? JSONSerialization.jsonObject(with: d) else { break }
            let before = tracks.count
            token = collect(obj, rendererKey: "playlistVideoRenderer", lockups: true, into: &tracks, seen: &seen)
            if tracks.count == before { break }
        }
        return tracks
    }

    private static func scrapeWatchPanel(video: String, list: String) async -> [Track] {
        guard let data = await get(URL(string: "https://www.youtube.com/watch?v=\(video)&list=\(list)&hl=en")!),
              let html = String(data: data, encoding: .utf8),
              let initial = extractJSON(after: "ytInitialData = ", in: html) else { return [] }
        var tracks: [Track] = []
        var seen = Set<String>()
        _ = collect(initial, rendererKey: "playlistPanelVideoRenderer", lockups: false, into: &tracks, seen: &seen)
        return tracks
    }
}
