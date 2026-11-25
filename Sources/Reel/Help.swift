import AppKit

/// Help → Reel Help (⌘?): a small window with how everything works.
final class HelpWindow: NSObject {
    static let shared = HelpWindow()
    private var window: NSWindow?

    private static let sections: [(String, [(String, String)])] = [
        ("Playing", [
            ("Click the video", "Play / pause — works even when Reel isn't the active app"),
            ("Double-click", "Full screen"),
            ("Space", "Play / pause"),
            ("← / →", "Back / forward 10 seconds"),
            ("↑ / ↓  or  ⇧← / ⇧→", "Previous / next track"),
            ("⇧↑ / ⇧↓", "Previous / next playlist"),
            ("L", "Loop this track (on by default for new tracks)"),
            ("M", "Mute"),
            ("Headset / media keys", "Play/pause, next and previous track — AirPods taps, headset buttons, ⏯ ⏭ ⏮ keys, Control Center"),
            ("F  or  ⌃⌘F", "Full screen (Esc leaves)"),
            ("Hover hotkeys", "Optional: Reel → Hotkeys While Hovering makes these keys work with the mouse over Reel even while another app is active"),
        ]),
        ("Seeking & volume", [
            ("Right-drag ← →", "Seek — the whole video is the bar; the unplayed part dims"),
            ("Right-drag ↑ ↓", "Volume"),
            ("", "Right-drag also works as two-finger-click drag on a trackpad, or ⌃-drag"),
            ("Two-finger swipe", "Same without clicking: sideways seeks, up/down is volume"),
            ("Mouse wheel", "Volume · ⇧ + wheel seeks"),
            ("Right-click", "A row of icons — play, loop, on top, playlist, add, paste, full screen (works even when Reel isn't focused)"),
        ]),
        ("Window", [
            ("Drag the video", "Move the window"),
            ("Drag an edge", "Resize — keeps the video's shape"),
            ("Screen edges", "Park it in a corner and it stays there when videos change shape"),
            ("⌘T", "Always on top (on by default)"),
            ("⌘0", "Actual size: the video's native resolution, or the screen size if that's smaller"),
            ("", "A new video keeps the same window area, so a tiny player stays tiny"),
        ]),
        ("Playlist", [
            ("⌘P  or blue circle", "Show / hide the playlist (top right, beside the window buttons)"),
            ("", "While it's open, resize freely: the playlist absorbs the width (min 250 px tall)"),
            ("", "Opening it shows what's playing"),
            ("Click a track", "Play it"),
            ("Double-click a title", "Rename a track (your name replaces the title)"),
            ("Drag rows", "Reorder · Delete key removes"),
            ("Right-click a track", "Icons: play, play next, rename, skip (strike through), Finder / copy link, copy to playlist, remove"),
            ("End of a playlist", "Goes round to the first track again"),
            ("Struck-through tracks", "Stay in the playlist but next / previous / auto-advance pass over them; click to play anyway"),
            ("Grayed out + Fix", "The file isn't on this Mac — Fix to point at it (others in that folder relink too)"),
            ("", "The list follows the playing track unless you scroll somewhere else"),
            ("Click the playlist's name", "Swaps to all your playlists (click again to go back). Click one to open it — it plays once you pick a track"),
            ("Right-click a playlist", "Rename, export, show in Finder, clear or delete · drag to reorder · drop files on one to add them there"),
            ("⌘N  or  + in that list", "New playlist, ready to name"),
            ("Bottom row", "⏮ ⏯ ⏭ 🔁 for what's playing (🔁 lights up when looping) · export · + add files"),
        ]),
        ("Adding media", [
            ("Drop on the video", "Plays it now, without adding it to a playlist"),
            ("Drop on the playlist", "Adds it right where you drop — dragging over the video opens the playlist so you can"),
            ("Not in a playlist", "While something plays that isn't in one, the playlist shows it with an Add button (also in the video's right-click icons)"),
            ("YouTube playlist link", "Asks: play without saving, save as a new playlist, add its videos to the one shown, or only this video"),
            ("Opened from Finder", "Plays once, outside your playlists (no loop)"),
            ("⌘V", "Pastes where the pointer is: a spot in the playlist adds it there, the video plays it now, elsewhere adds it to the end"),
            ("+  or  ⌘O", "Choose files"),
            ("Works with", "Video & audio files, direct links, HLS streams, YouTube videos and playlists, Bilibili"),
            ("WebM", "Plays too; transparent WebM is see-through, with glass behind it while the playlist or window buttons show"),
            ("Unusual formats", "Videos macOS can't decode play through Reel's built-in FFmpeg decoder"),
            ("Audio only", "Shows the waveform"),
        ]),
        ("Sharing playlists", [
            ("Export button", "Saves the shown playlist as a .reel file (name, link, loop, skip per track)"),
            ("Where they live", "Each playlist is a .reel file in ~/Library/Application Support/Reel/Playlists"),
            ("Open a .reel file", "Double-click it: it plays right away, marked Not saved — Save keeps it with your playlists"),
            ("Drop a .reel file", "Asks, like a YouTube playlist: play without saving, save as a new playlist, or add its items to the one shown"),
        ]),
        ("On launch", [
            ("", "Reel loads the first item of the playlist you used last, paused"),
            ("", "It checks GitHub for a newer version and offers to update (also: Reel → Check for Updates…)"),
            ("Default player", "Reel → Default Video Player / Default Music Player makes double-clicked files open in Reel (macOS asks you to confirm each file type)"),
        ]),
    ]

    func show() {
        if window == nil { window = makeWindow() }
        window?.level = Prefs.alwaysOnTop ? .floating : .normal   // don't open behind a floating player
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Reel Help"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.minSize = NSSize(width: 380, height: 300)

        let scroll = NSScrollView(frame: w.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let text = NSTextView(frame: scroll.bounds)
        text.autoresizingMask = [.width]
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 26, height: 40)
        text.textStorage?.setAttributedString(Self.content())
        scroll.documentView = text

        let bg: NSView
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView(); g.cornerRadius = 0; bg = g
        } else {
            let v = NSVisualEffectView(); v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active; bg = v
        }
        bg.frame = w.contentView!.bounds
        bg.autoresizingMask = [.width, .height]
        let root = NSView(frame: w.contentView!.bounds)
        root.addSubview(bg)
        root.addSubview(scroll)
        w.contentView = root
        w.isOpaque = false
        w.backgroundColor = .clear
        return w
    }

    private static func content() -> NSAttributedString {
        let out = NSMutableAttributedString()
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: NSColor.white]
        out.append(NSAttributedString(string: "Reel\n", attributes: title))
        out.append(NSAttributedString(string: "A tiny, QuickTime-style player with playlists.\n",
                                      attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white.withAlphaComponent(0.6)]))
        let head: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white]
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .left, location: 170)]
        para.headIndent = 170
        para.paragraphSpacing = 4
        let key: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                                                  .foregroundColor: NSColor.white.withAlphaComponent(0.92), .paragraphStyle: para]
        let val: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5),
                                                  .foregroundColor: NSColor.white.withAlphaComponent(0.68), .paragraphStyle: para]
        for (section, rows) in sections {
            out.append(NSAttributedString(string: "\n\(section)\n", attributes: head))
            let spacer = NSMutableParagraphStyle(); spacer.paragraphSpacing = 6
            out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 4), .paragraphStyle: spacer]))
            for (k, v) in rows {
                out.append(NSAttributedString(string: k, attributes: key))
                out.append(NSAttributedString(string: "\t" + v + "\n", attributes: val))
            }
        }
        return out
    }
}

/// Reel → About Reel: icon, name, version, what it does, and a couple of handy buttons.
final class AboutWindow: NSObject {
    static let shared = AboutWindow()
    private var window: NSWindow?

    func show() {
        if window == nil { window = make() }
        window?.level = Prefs.alwaysOnTop ? .floating : .normal
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func label(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, alpha: CGFloat = 1) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = NSColor.white.withAlphaComponent(alpha)
        l.alignment = .center
        l.isSelectable = false
        return l
    }

    private func chip(_ s: String) -> NSView {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 11, weight: .medium)
        l.textColor = NSColor.white.withAlphaComponent(0.85)
        l.sizeToFit()
        let v = NSView(frame: NSRect(x: 0, y: 0, width: l.frame.width + 18, height: 22))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.1).cgColor
        v.layer?.cornerRadius = 11
        l.frame.origin = NSPoint(x: 9, y: (22 - l.frame.height) / 2)
        v.addSubview(l)
        return v
    }

    private func make() -> NSWindow {
        let W: CGFloat = 380, H: CGFloat = 470
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.isOpaque = false
        w.backgroundColor = .clear

        let root = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        let bg: NSView
        if #available(macOS 26.0, *) { let g = NSGlassEffectView(); g.cornerRadius = 0; bg = g }
        else { let v = NSVisualEffectView(); v.material = .hudWindow; v.blendingMode = .behindWindow; v.state = .active; bg = v }
        bg.frame = root.bounds
        root.addSubview(bg)

        var y = H - 44
        func place(_ v: NSView, height: CGFloat, gap: CGFloat = 0) {
            y -= height + gap
            v.frame = NSRect(x: 30, y: y, width: W - 60, height: height)
            root.addSubview(v)
        }

        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        place(icon, height: 112)

        place(label("Reel", size: 28, weight: .bold), height: 34, gap: 10)
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String).map { "v" + $0 } ?? "development build"
        place(label("Version \(version)", size: 12, alpha: 0.5), height: 16, gap: 2)
        place(label("A tiny, QuickTime-style player that stays on top — with playlists, per-track loop, and glass.",
                    size: 13, alpha: 0.8), height: 36, gap: 16)

        // What it plays
        let chips = ["Video & audio files", "YouTube", "Bilibili", "WebM", "HLS", "Direct links"].map(chip)
        var rows: [[NSView]] = [[]]
        var rowW: CGFloat = 0
        for c in chips {
            if rowW + c.frame.width > W - 60, !rows[rows.count - 1].isEmpty { rows.append([]); rowW = 0 }
            rows[rows.count - 1].append(c); rowW += c.frame.width + 6
        }
        y -= 18
        for r in rows {
            let total = r.reduce(0) { $0 + $1.frame.width } + CGFloat(r.count - 1) * 6
            var x = (W - total) / 2
            y -= 22
            for c in r { c.frame.origin = NSPoint(x: x, y: y); root.addSubview(c); x += c.frame.width + 6 }
            y -= 6
        }

        // Buttons
        let help = NSButton(title: "Help", target: self, action: #selector(openHelp))
        let lib = NSButton(title: "Playlists Folder", target: self, action: #selector(openLibrary))
        for b in [help, lib] { b.bezelStyle = .push; b.controlSize = .large; b.sizeToFit() }
        let bw = help.frame.width + lib.frame.width + 10
        y -= 46
        help.frame.origin = NSPoint(x: (W - bw) / 2, y: y)
        lib.frame.origin = NSPoint(x: help.frame.maxX + 10, y: y)
        root.addSubview(help); root.addSubview(lib)

        let foot = label("Built with Swift · AppKit · AVFoundation · WebKit\nIncludes FFmpeg (LGPL) and libvpx (BSD) · © 2026", size: 11, alpha: 0.4)
        foot.frame = NSRect(x: 30, y: 18, width: W - 60, height: 30)
        root.addSubview(foot)

        w.contentView = root
        return w
    }

    @objc private func openHelp() { HelpWindow.shared.show() }
    @objc private func openLibrary() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Reel")
        NSWorkspace.shared.activateFileViewerSelecting([dir.appendingPathComponent("library.json")])
    }
}
