import AppKit

/// Checks GitHub for a newer release on launch (and from Reel → Check for Updates…),
/// and can install it in place: download, swap the app bundle, relaunch.
enum Updater {
    static let repo = "kaioker/reel"
    /// Called right before quitting to install an update (saves where playback is).
    static var willRelaunch: (() -> Void)?
    /// True while quitting to install an update (so the saved spot resumes playing, not paused).
    static var isRelaunching = false

    struct Release { var tag: String; var version: [Int]; var zipURL: URL? }

    static var currentVersionString: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }

    /// "v26.48.03" / "26.48.03" → [26, 48, 3]
    static func parse(_ s: String) -> [Int] {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").compactMap { Int($0) }
    }

    static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static var gh: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    static func run(_ exe: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    /// Public repos answer the GitHub API directly; private ones go through your logged-in `gh`.
    static func latest() async -> Release? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Reel-updater", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        if let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tag = obj["tag_name"] as? String {
            let assets = obj["assets"] as? [[String: Any]] ?? []
            let zip = assets.first { ($0["name"] as? String) == "Reel.zip" }?["browser_download_url"] as? String
            return Release(tag: tag, version: parse(tag), zipURL: zip.flatMap(URL.init(string:)))
        }
        guard let gh else { return nil }
        let (code, tag) = await Task.detached { run(gh, ["release", "view", "--repo", repo, "--json", "tagName", "--jq", ".tagName"]) }.value
        guard code == 0, !tag.isEmpty else { return nil }
        return Release(tag: tag, version: parse(tag), zipURL: nil)
    }

    /// `interactive`: also say "you're up to date" / "couldn't check" (menu item). On launch it stays quiet unless there's an update.
    @MainActor
    static func check(interactive: Bool, window: NSWindow?) async {
        guard let cur = currentVersionString else {
            if interactive { alert("Updates aren't available for development builds.", nil, window: window) }
            return
        }
        guard let rel = await latest() else {
            if interactive { alert("Couldn't check for updates.", "Make sure you're online" + (gh == nil ? " and the GitHub CLI is installed and logged in (brew install gh, gh auth login)." : " and logged in to GitHub (gh auth login)."), window: window) }
            return
        }
        guard isNewer(rel.version, than: parse(cur)) else {
            if interactive { alert("Reel is up to date.", "You have v\(cur), the newest version.", window: window) }
            return
        }
        let a = NSAlert()
        a.messageText = "Reel \(rel.tag) is available"
        a.informativeText = "You have v\(cur). Update now? Reel will restart."
        a.addButton(withTitle: "Update")
        a.addButton(withTitle: "Later")
        let respond: (NSApplication.ModalResponse) -> Void = { r in
            if r == .alertFirstButtonReturn { Task { await install(rel, window: window) } }
        }
        if let window { a.beginSheetModal(for: window, completionHandler: respond) } else { respond(a.runModal()) }
    }

    @MainActor
    static func install(_ rel: Release, window: NSWindow?) async {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("reel-update-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let zip = tmp.appendingPathComponent("Reel.zip")
        var ok = false
        if let url = rel.zipURL, let (file, _) = try? await URLSession.shared.download(from: url) {
            ok = (try? FileManager.default.moveItem(at: file, to: zip)) != nil
        } else if let gh {
            ok = await Task.detached { run(gh, ["release", "download", rel.tag, "--repo", repo, "--pattern", "Reel.zip", "--dir", tmp.path]).0 == 0 }.value
        }
        let unzipped = tmp.appendingPathComponent("new")
        if ok { ok = await Task.detached { run("/usr/bin/ditto", ["-x", "-k", zip.path, unzipped.path]).0 == 0 }.value }
        let newApp = unzipped.appendingPathComponent("Reel.app")
        guard ok, FileManager.default.fileExists(atPath: newApp.path) else {
            alert("The update couldn't be downloaded.", "Try again later, or run ./install.sh.", window: window)
            return
        }
        // Swap the bundle after we quit, then relaunch.
        let target = Bundle.main.bundleURL.path
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(target)"
        /usr/bin/ditto "\(newApp.path)" "\(target)"
        /usr/bin/xattr -dr com.apple.quarantine "\(target)" 2>/dev/null
        \(ProcessInfo.processInfo.environment["REEL_UPDATE_NOOPEN"] == nil ? "/usr/bin/open \"\(target)\"" : "")
        rm -rf "\(tmp.path)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", script]
        try? p.run()
        isRelaunching = true
        willRelaunch?()
        Library.shared.saveNow()
        NSApp.terminate(nil)
    }

    @MainActor
    private static func alert(_ title: String, _ info: String?, window: NSWindow?) {
        let a = NSAlert()
        a.messageText = title
        if let info { a.informativeText = info }
        if let window { a.beginSheetModal(for: window) } else { a.runModal() }
    }
}
