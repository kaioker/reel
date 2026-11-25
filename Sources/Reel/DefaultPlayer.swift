import AppKit
import UniformTypeIdentifiers

/// Reel → Default Video Player / Default Music Player: make Reel what opens video (or audio) files when
/// you double-click them in Finder. macOS keeps a default app per file type and asks you to confirm each
/// change, so this goes through the common types one at a time (one confirmation each) and stops if you
/// decline. Turning it off hands each type back to the app it had before.
enum DefaultPlayer {
    enum Kind: String {
        case video, music
        var label: String { self == .video ? "video" : "music" }
        /// What Finder files these under; checked to show the menu's checkmark.
        var mainType: UTType { self == .video ? .mpeg4Movie : .mp3 }
        /// Who gets the files back if nothing else was remembered.
        var fallbackApp: String { self == .video ? "/System/Applications/QuickTime Player.app" : "/System/Applications/Music.app" }
        /// The common types only: macOS asks once for each.
        var extensions: [String] {
            switch self {
            case .video: return ["mp4", "mov", "m4v", "mkv", "webm", "avi"]
            case .music: return ["mp3", "m4a", "wav", "flac", "aac"]
            }
        }
    }

    /// The installed Reel.app (a development binary isn't an app macOS can hand files to).
    static var appURL: URL? { Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL : nil }

    static func types(_ k: Kind) -> [UTType] {
        var seen = Set<String>(), out: [UTType] = []
        for e in k.extensions {
            guard let t = UTType(filenameExtension: e), !t.isDynamic, seen.insert(t.identifier).inserted else { continue }
            out.append(t)
        }
        return out
    }

    private static func isReel(_ app: URL?) -> Bool {
        guard let app else { return false }
        return Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    static func isDefault(_ k: Kind) -> Bool { appURL != nil && isReel(NSWorkspace.shared.urlForApplication(toOpen: k.mainType)) }

    private static func previousKey(_ k: Kind) -> String { "defaultPlayer.previous.\(k.rawValue)" }

    enum Outcome { case done(changed: Int), declined(changed: Int), failed(changed: Int) }

    /// Makes Reel the default for each type of this kind (remembering who had it), or hands them back.
    @MainActor
    static func set(_ k: Kind, on: Bool) async -> Outcome {
        guard let me = appURL else { return .failed(changed: 0) }
        let ws = NSWorkspace.shared
        var saved = UserDefaults.standard.dictionary(forKey: previousKey(k)) as? [String: String] ?? [:]
        var changed = 0
        for t in types(k) {
            let current = ws.urlForApplication(toOpen: t)
            let target: URL
            if on {
                if isReel(current) { continue }                               // already Reel
                if let current { saved[t.identifier] = current.path }
                target = me
            } else {
                guard isReel(current) else { continue }                       // you've since picked something else
                target = saved[t.identifier].map { URL(fileURLWithPath: $0) }
                    .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? URL(fileURLWithPath: k.fallbackApp)
            }
            do {
                try await ws.setDefaultApplication(at: target, toOpen: t)   // macOS shows its confirmation here
                changed += 1
                UserDefaults.standard.set(saved, forKey: previousKey(k))
            } catch {
                if debugLog { print("default \(k.label): \(t.identifier) → \(target.lastPathComponent): \(error)"); fflush(stdout) }
                let cancelled = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(userCanceledErr)
                    || (error as NSError).code == NSUserCancelledError
                return cancelled ? .declined(changed: changed) : .failed(changed: changed)
            }
        }
        if !on { UserDefaults.standard.removeObject(forKey: previousKey(k)) }
        return .done(changed: changed)
    }
}
