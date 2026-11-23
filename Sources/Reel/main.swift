import AppKit
import VideoToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    var player: PlayerController!
    private var pendingOpen: [URL] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        Updater.willRelaunch = { [weak self] in self?.player.saveResumePoint() }
        showWelcomeIfFreshInstall()
        player = PlayerController()
        player.showWindow()
        if !pendingOpen.isEmpty { player.open(files: pendingOpen); pendingOpen = [] }
        // REEL_PLAY="<url or path>" adds it to the shown playlist and plays it (handy from a terminal)
        let env = ProcessInfo.processInfo.environment
        if Bundle.main.bundleURL.pathExtension == "app",
           !env.keys.contains(where: { $0.hasPrefix("REEL_") }) || env["REEL_STARTUP_UPDATE_TEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                Task { @MainActor in await Updater.check(interactive: false, window: self.player.window) }
            }
        }
        if env["REEL_PLAY"] == nil && !env.keys.contains(where: { $0.hasSuffix("_TEST") }) || env["REEL_AUTOPLAY_TEST"] != nil || env["REEL_RESUME_TEST"] == "check" {
            // Give a file opened from Finder/Dock a moment to arrive first; it wins.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if !self.player.resumeIfSaved() { self.player.autoplayLastPlaylist() }
            }
        }
        if let u = ProcessInfo.processInfo.environment["REEL_PLAY"] {
            if u == "first" { player.nextTrack() } else { player.panel.add(text: u, at: nil, playFirst: true) }
        }
        let testing = ["REEL_DEBUG", "REEL_PANEL_TEST", "REEL_GESTURE_TEST", "REEL_DOT_TEST", "REEL_RESIZE_TEST", "REEL_CLICK_TEST", "REEL_HELP_TEST", "REEL_RCLICK_TEST", "REEL_FOLLOW_TEST", "REEL_SKIP_TEST", "REEL_FLASH_TEST", "REEL_IO_TEST", "REEL_FIRSTCLICK_TEST", "REEL_FIT_TEST", "REEL_ABOUT_TEST", "REEL_DISMISS_TEST", "REEL_DROP_TEST", "REEL_VOLUME_TEST"].contains { ProcessInfo.processInfo.environment[$0] != nil }
        if !testing { NSApp.activate(ignoringOtherApps: true) }
        if let dir = ProcessInfo.processInfo.environment["REEL_DOT_TEST"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                // Native inactive button's own pixels (with alpha), to match its translucency.
                if let close = self.player.window.standardWindowButton(.closeButton) { let w = self.player.window
                    let rep = close.bitmapImageRepForCachingDisplay(in: close.bounds)!
                    close.cacheDisplay(in: close.bounds, to: rep)
                    for (x, y) in [(rep.pixelsWide / 2, rep.pixelsHigh / 2), (rep.pixelsWide / 2 + rep.pixelsWide / 4, rep.pixelsHigh / 2)] {
                        let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                        print(String(format: "native inactive px(%d,%d) rgba %.3f %.3f %.3f a=%.3f  key=%d", x, y, c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent, w.isKeyWindow ? 1 : 0))
                    }
                    fflush(stdout)
                }
                // Render the real title bar: native buttons on the left, our dot on the right, in 3 states.
                let w = self.player.window
                guard let bar = w.standardWindowButton(.closeButton)?.superview,
                      let dot = bar.subviews.first(where: { $0 is PlaylistDot }) as? PlaylistDot else { NSApp.terminate(nil); return }
                bar.alphaValue = 1
                var strips: [NSBitmapImageRep] = []
                for (act, hov) in [(true, false), (true, true), (false, false)] {
                    dot.active = act; dot.hovering = hov
                    let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds)!
                    bar.cacheDisplay(in: bar.bounds, to: rep)
                    strips.append(rep)
                }
                // compose: left 80pt + right 30pt of each state, stacked, at 4x
                let H = bar.bounds.height, W = bar.bounds.width
                let out = NSImage(size: NSSize(width: 110 * 4, height: H * 3 * 4))
                out.lockFocus()
                NSGraphicsContext.current?.imageInterpolation = .none
                NSColor(white: 0.08, alpha: 1).setFill(); NSRect(origin: .zero, size: out.size).fill()
                for (i, rep) in strips.enumerated() {
                    let y = CGFloat(2 - i) * H * 4
                    rep.draw(in: NSRect(x: 0, y: y, width: 80 * 4, height: H * 4), from: NSRect(x: 0, y: 0, width: 80, height: H), operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    rep.draw(in: NSRect(x: 80 * 4, y: y, width: 30 * 4, height: H * 4), from: NSRect(x: W - 30, y: 0, width: 30, height: H), operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
                out.unlockFocus()
                try? NSBitmapImageRep(data: out.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir + "/dots.png"))
                NSApp.terminate(nil)
            }
        }
        if ProcessInfo.processInfo.environment["REEL_CLICK_TEST"] != nil {
            let pl = self.player!
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { pl.setPanel(open: true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                let w = pl.window, panel = pl.panel, table = panel.table
                func click(_ pWin: NSPoint, count: Int) {
                    for n in 1...count {
                        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: pWin, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: n, pressure: 1)!
                        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: pWin, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: n, pressure: 0)!
                        NSApp.postEvent(up, atStart: true)   // so tracking loops see the release
                        w.sendEvent(down)
                        if NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: false) != nil { w.sendEvent(NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true)!) }
                    }
                }
                func titlePoint(row: Int) -> NSPoint {
                    let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as! TrackCell
                    return cell.title.convert(NSPoint(x: 10, y: cell.title.bounds.midY), to: nil)
                }
                let name = { (i: Int) in panel.tracks[i].displayName }
                print("playing:", pl.nowPlayingTrackID.flatMap { id in panel.tracks.first { $0.id == id }?.displayName } ?? "-")
                click(titlePoint(row: 1), count: 1)
                print("after single click on \(name(1)): playing:", pl.nowPlayingTrackID.flatMap { id in panel.tracks.first { $0.id == id }?.displayName } ?? "-")
                click(titlePoint(row: 2), count: 2)
                let cell2 = table.view(atColumn: 0, row: 2, makeIfNecessary: false) as! TrackCell
                print("double-click title of \(name(2)): renaming=\(cell2.title.editingName)")
                w.makeFirstResponder(w.contentView)
                let np = panel.nameField.convert(NSPoint(x: 8, y: panel.nameField.bounds.midY), to: nil)
                let hit = w.contentView?.superview?.hitTest(np)
                print("name field frame in window: \(panel.nameField.convert(panel.nameField.bounds, to: nil)), close button: \(w.standardWindowButton(.closeButton)!.convert(w.standardWindowButton(.closeButton)!.bounds, to: nil)), hit view at name: \(hit.map { String(describing: type(of: $0)) } ?? "nil")")
                click(np, count: 2)
                print("double-click playlist name: renaming=\(panel.nameField.editingName)")
                fflush(stdout); NSApp.terminate(nil)
            }
        }
        if let out = ProcessInfo.processInfo.environment["REEL_EXPORT_TEST"] {
            let pl = self.player!
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let src = Library.shared.playlist(pl.panel.shownID)!
                try! pl.panel.exportData(src).write(to: URL(fileURLWithPath: out))
                print("exported \(src.name) (\(src.tracks.count) tracks) to \(URL(fileURLWithPath: out).lastPathComponent)")
                let pb = NSPasteboard(name: NSPasteboard.Name("reel-export-test-\(getpid())"))
                pb.clearContents(); pb.writeObjects([URL(fileURLWithPath: out) as NSURL])
                pl.panel.acceptExternal(pb, at: nil, playFirst: true)   // same path as dropping on the video
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    for p in Library.shared.playlists { print("playlist:", p.name, "tracks:", p.tracks.map(\.displayName), "loop:", p.tracks.map(\.loop)) }
                    print("now showing:", Library.shared.playlist(pl.panel.shownID)!.name, " playing:", pl.nowPlayingTrackID.flatMap { id in Library.shared.playlists.flatMap(\.tracks).first { $0.id == id }?.displayName } ?? "-")
                    pb.releaseGlobally(); fflush(stdout); NSApp.terminate(nil)
                }
            }
        }
        if ProcessInfo.processInfo.environment["REEL_RESIZE_TEST"] == "panel" {
            let pl = self.player!
            pl.setPanel(open: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let w = pl.window, f = w.frame.size
                print("open: \(Int(f.width))x\(Int(f.height))  (video 16:9 + playlist)")
                for (label, sz) in [("wider +150", NSSize(width: f.width + 150, height: f.height)),
                                    ("taller +80", NSSize(width: f.width, height: f.height + 80)),
                                    ("narrower -250", NSSize(width: f.width - 250, height: f.height)),
                                    ("huge width", NSSize(width: f.width + 2000, height: f.height))] {
                    let r = pl.windowWillResize(w, to: sz)
                    let vw = (r.height * 16 / 9).rounded()
                    print("\(label): proposed \(Int(sz.width))x\(Int(sz.height)) -> \(Int(r.width))x\(Int(r.height))  video≈\(Int(min(vw, r.width - 220)))  playlist≈\(Int(r.width - min(vw, r.width - 220)))")
                }
                fflush(stdout); NSApp.terminate(nil)
            }
        } else if ProcessInfo.processInfo.environment["REEL_RESIZE_TEST"] != nil {
            let w = player.window
            NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: w)
            player.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification, object: w))
            let f = w.frame.size
            var out: [String] = []
            // diagonal corner drag with cursor jitter: width/height grow unevenly step to step
            for i in 1...12 {
                let jw = CGFloat(i * 20 + (i % 2 == 0 ? 9 : -9)), jh = CGFloat(i * 14 + (i % 2 == 0 ? -8 : 8))
                let r = player.windowWillResize(w, to: NSSize(width: f.width + jw, height: f.height + jh))
                out.append("\(Int(r.width))x\(Int(r.height))")
            }
            print("start \(Int(f.width))x\(Int(f.height)) ->", out.joined(separator: " ")); fflush(stdout)
            NSApp.terminate(nil)
        }
        if let text = ProcessInfo.processInfo.environment["REEL_PASTE_TEST"] {
            let pb = NSPasteboard(name: NSPasteboard.Name("reel-test-\(getpid())"))
            pb.clearContents(); pb.setString(text, forType: .string)
            player.panel.acceptExternal(pb, at: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                for t in self.player.panel.tracks { print("added:", t.kind.rawValue, t.displayName) }
                pb.releaseGlobally(); fflush(stdout); NSApp.terminate(nil)
            }
        }
        if let dir = ProcessInfo.processInfo.environment["REEL_GESTURE_TEST"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.player.runGestureTest(snapshotDir: dir) }
        }
        if ProcessInfo.processInfo.environment["REEL_RCLICK_TEST"] != nil {
            let pl = self.player!
            pl.setPanel(open: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let w = pl.window, table = pl.panel.table
                func ev(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
                    NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                }
                print("window focused: \(w.isKeyWindow)")
                // 1. right-drag on the video → seek (through the window's real event routing)
                let video = w.contentView!.subviews.first!
                let b = video.convert(video.bounds, to: nil)
                let t0 = pl.debugCurrentTime
                w.sendEvent(ev(.rightMouseDown, NSPoint(x: b.minX + b.width * 0.1, y: b.midY)))
                w.sendEvent(ev(.rightMouseDragged, NSPoint(x: b.minX + b.width * 0.4, y: b.midY + 2)))
                w.sendEvent(ev(.rightMouseDragged, NSPoint(x: b.minX + b.width * 0.8, y: b.midY + 2)))
                w.sendEvent(ev(.rightMouseUp, NSPoint(x: b.minX + b.width * 0.8, y: b.midY + 2)))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    print(String(format: "unfocused right-drag to 80%%: t %.1f -> %.1f", t0, pl.debugCurrentTime))
                    // 2. right-click a partially visible track row → menu opens for that row
                    guard let clip = table.enclosingScrollView?.contentView else { return }
                    clip.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: 1).minY + 21)); table.enclosingScrollView?.reflectScrolledClipView(clip)
                    let r = table.rect(ofRow: 1).intersection(clip.documentVisibleRect)
                    let p = table.convert(NSPoint(x: r.midX, y: r.midY), to: nil)
                    w.sendEvent(ev(.rightMouseDown, p))
                    w.sendEvent(ev(.rightMouseUp, p))
                    print("unfocused right-click on half-hidden row 1: icon menu showing=\(IconMenu.shared.isShowing) selected row=\(table.selectedRow)")
                    fflush(stdout)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {   // time for a screenshot
                        IconMenu.shared.close()
                        let vp = NSPoint(x: b.midX, y: b.midY)
                        w.sendEvent(ev(.rightMouseDown, vp)); w.sendEvent(ev(.rightMouseUp, vp))
                        print("unfocused right-click on video: icon menu showing=\(IconMenu.shared.isShowing)")
                        fflush(stdout)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { NSApp.terminate(nil) }
                    }
                }
            }
        }
        if ProcessInfo.processInfo.environment["REEL_FOLLOW_TEST"] != nil {
            let pl = self.player!, panel = pl.panel, table = panel.table
            pl.setPanel(open: true)
            func vis() -> String {
                let v = table.enclosingScrollView!.contentView.documentVisibleRect
                let rows = table.rows(in: v)
                return "visible rows \(rows.location)…\(rows.location + rows.length - 1)"
            }
            func playing() -> String { pl.nowPlayingTrackID.flatMap { id in panel.tracks.first { $0.id == id }?.displayName } ?? "-" }
            var steps: [() -> Void] = []
            steps.append { for _ in 0..<10 { pl.nextTrack() } }
            steps.append { print("after ↓×10: playing \(playing()), \(vis()), following=\(panel.followsCurrent)") }
            steps.append {   // user scrolls back to the top (a live scroll)
                let clip = table.enclosingScrollView!.contentView
                clip.setBoundsOrigin(.zero); table.enclosingScrollView!.reflectScrolledClipView(clip)
                NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: table.enclosingScrollView)
                print("user scrolled to top: \(vis()), following=\(panel.followsCurrent)")
                pl.nextTrack()
            }
            steps.append { print("↓ while scrolled away: playing \(playing()), \(vis()) (should stay put)") }
            steps.append {   // play next: pick row 2 → should land right after the current track
                table.selectRowIndexes([2], byExtendingSelection: false)
                let name = panel.tracks[2].displayName
                panel.playNext()
                let cur = panel.tracks.firstIndex { $0.id == pl.nowPlayingTrackID }!
                print("play next '\(name)': current at \(cur), next is '\(panel.tracks[cur + 1].displayName)'")
            }
            for (i, st) in steps.enumerated() { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + Double(i) * 0.6, execute: st) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + Double(steps.count) * 0.6) { fflush(stdout); NSApp.terminate(nil) }
        }
        if ProcessInfo.processInfo.environment["REEL_SKIP_TEST"] != nil {
            let pl = self.player!, panel = pl.panel
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                func playing() -> String { pl.nowPlayingTrackID.flatMap { id in panel.tracks.first { $0.id == id }?.displayName } ?? "-" }
                print("loaded old library: \(panel.tracks.count) tracks, playing \(playing())")
                // strike Track 0, Track 1 (rows 1, 2) and the last one
                for r in [1, 2, panel.tracks.count - 1] { Library.shared.mutateTrack(panel.tracks[r].id) { $0.skip = true } }
                pl.nextTrack()
                print("↓ from Long clip with Track 0 & 1 struck: \(playing())")
                pl.prevTrack()
                print("↑ back: \(playing())")
                pl.panelPlay(playlist: panel.shownID, track: panel.tracks[1].id)
                print("click struck Track 0: \(playing())")
                pl.panelPlay(playlist: panel.shownID, track: panel.tracks[panel.tracks.count - 2].id)
                pl.nextTrack(auto: true)
                print("auto-advance from 2nd-to-last with last struck: still \(playing()) (stops)")
                print("saved skip flags:", Library.shared.playlists[0].tracks.map { $0.isSkipped ? "S" : "." }.joined())
                fflush(stdout); NSApp.terminate(nil)
            }
        }
        if let out = ProcessInfo.processInfo.environment["REEL_FLASH_TEST"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.player.togglePlay()   // → paused, flashes ⏸
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    p.arguments = ["-x", "-o", "-l\(self.player.window.windowNumber)", out]
                    try? p.run(); p.waitUntilExit()
                    NSApp.terminate(nil)
                }
            }
        }
        if let dir = ProcessInfo.processInfo.environment["REEL_AUDIO_TEST"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let files = (try? FileManager.default.contentsOfDirectory(atPath: dir))!.sorted().map { URL(fileURLWithPath: dir + "/" + $0) }
                for f in files { print("isMedia(\(f.lastPathComponent)) =", MediaResolver.isMedia(f)) }
                let pb = NSPasteboard(name: NSPasteboard.Name("reel-audio-\(getpid())"))
                pb.clearContents(); pb.writeObjects(files as [NSURL])
                let ok = self.player.panel.acceptExternal(pb, at: nil, playFirst: true)
                print("drop accepted:", ok, " playlist now:", self.player.panel.tracks.map(\.displayName))
                var i = 0
                func next() {
                    guard i < self.player.panel.tracks.count else { pb.releaseGlobally(); NSApp.terminate(nil); return }
                    let t = self.player.panel.tracks[i]; i += 1
                    self.player.panelPlay(playlist: self.player.panel.shownID, track: t.id)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        print(String(format: "  %@ → playing=%@ t=%.1f", t.displayName, self.player.debugIsPlaying ? "yes" : "no", self.player.debugCurrentTime)); fflush(stdout)
                        next()
                    }
                }
                next()
            }
        }
        if ProcessInfo.processInfo.environment["REEL_ALIGN_TEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let w = self.player.window
                let close = w.standardWindowButton(.closeButton)!
                let dot = close.superview!.subviews.first { $0 is PlaylistDot } ?? w.contentView!.superview!.subviews.flatMap { $0.subviews }.flatMap { [$0] + $0.subviews }.first { $0 is PlaylistDot }
                let c = close.convert(close.bounds, to: nil), d = dot!.convert(dot!.bounds, to: nil)
                print(String(format: "window %.0f wide · close center (%.1f, %.1f) · dot center (%.1f, %.1f) · left gap %.1f vs right gap %.1f · nesting: close in %@", w.frame.width, c.midX, c.midY, d.midX, d.midY, c.minX, w.frame.width - d.maxX, String(describing: type(of: close.superview!))))
                fflush(stdout); NSApp.terminate(nil)
            }
        }
        if let mode = ProcessInfo.processInfo.environment["REEL_UPDATE_TEST"] {
            Task { @MainActor in
                let cur = Updater.currentVersionString ?? "none"
                guard let rel = await Updater.latest() else { print("lookup failed"); fflush(stdout); NSApp.terminate(nil); return }
                print("latest on GitHub: \(rel.tag) via \(rel.zipURL == nil ? "gh (private repo)" : "public API")  this build: \(cur)  newer? \(Updater.isNewer(rel.version, than: Updater.parse(cur)))")
                print("compare checks:", Updater.isNewer([26,48,3], than: [26,48,2]), Updater.isNewer([26,49,1], than: [26,48,9]), Updater.isNewer([27,1,1], than: [26,52,40]), !Updater.isNewer([26,48,3], than: [26,48,3]))
                fflush(stdout)
                if mode == "install" { await Updater.install(rel, window: nil) } else { NSApp.terminate(nil) }
            }
        }
        if let out = ProcessInfo.processInfo.environment["REEL_FLASH2_TEST"] {
            // flash several times (as repeated clicks would), then capture one held frame
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                for _ in 0..<3 { self.player.togglePlay() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.player.togglePlay()
                    self.player.debugHoldFlash()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                        p.arguments = ["-x", "-o", "-l\(self.player.window.windowNumber)", out]; try? p.run(); p.waitUntilExit()
                        NSApp.terminate(nil)
                    }
                }
            }
        }
        if let clip = ProcessInfo.processInfo.environment["REEL_BATCH_TEST"] {
            NSApp.activate(ignoringOtherApps: true); self.player.window.makeKeyAndOrderFront(nil)
            let pl = self.player!, panel = pl.panel
            func playing() -> String { pl.nowPlayingTrackID.flatMap { id in Library.shared.playlists.flatMap(\.tracks).first { $0.id == id }?.displayName } ?? (pl.nowPlayingTrackID == nil ? "-" : "(opened file)") }
            func key(_ code: UInt16) {
                let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: pl.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
                NSApp.sendEvent(e)
            }
            var steps: [(Double, () -> Void)] = []
            steps.append((1.0, {
                let before = Library.shared.playlists.flatMap(\.tracks).count
                pl.open(files: [URL(fileURLWithPath: clip)])
                print("1. opened from Finder: playing \(playing()), library tracks \(before) → \(Library.shared.playlists.flatMap(\.tracks).count), lastPlaylist unchanged: \(Prefs.lastPlaylist == ProcessInfo.processInfo.environment["REEL_EXPECT_LAST"])")
            }))
            steps.append((5.0, { print("   after the 3 s clip ended: still playing? \(pl.debugIsPlaying)  (should be false — played once, no loop)") }))
            steps.append((0.5, {
                print("2. playlist open before paste: \(pl.panelOpen)")
                let pb = NSPasteboard(name: NSPasteboard.Name("reel-batch-\(getpid())")); pb.clearContents(); pb.writeObjects([URL(fileURLWithPath: clip) as NSURL])
                _ = panel.acceptExternal(pb, at: nil, playFirst: false)
            }))
            steps.append((0.8, { print("   after paste: playlist open \(pl.panelOpen), selected row \(panel.table.selectedRow) of \(panel.tracks.count) in “\(Library.shared.playlist(panel.shownID)!.name)”") }))
            steps.append((0.3, { key(125) }))
            steps.append((0.5, { print("3. ⇧↓ → showing “\(Library.shared.playlist(panel.shownID)!.name)”, playing \(playing())"); key(124) }))
            steps.append((0.5, { print("   ⇧→ → playing \(playing())"); key(126) }))
            steps.append((0.5, { print("   ⇧↑ → showing “\(Library.shared.playlist(panel.shownID)!.name)”") }))
            steps.append((0.1, { Task { @MainActor in
                print("4. YouTube playlist title:", await MediaResolver.youtubePlaylistTitle("PL0BAFA2DA294B0900") ?? "nil")
                print("   playlist links found in a paste:", MediaResolver.youtubePlaylistLinks(in: "see https://www.youtube.com/watch?v=dhzPnX07jAs&list=PL0BAFA2DA294B0900 and https://youtu.be/abc").map { "\($0.video ?? "-")/\($0.list)" })
                fflush(stdout); NSApp.terminate(nil) } }))
            var t = 0.0
            for (d, f) in steps { t += d; DispatchQueue.main.asyncAfter(deadline: .now() + t) { f(); fflush(stdout) } }
        }
        if let mode = ProcessInfo.processInfo.environment["REEL_RESUME_TEST"] {
            if mode == "save" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self.player.debugSeek(23.0)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        print(String(format: "before restart: t=%.1f playing=%@", self.player.debugCurrentTime, self.player.debugIsPlaying ? "yes" : "no"))
                        Updater.willRelaunch?(); fflush(stdout); NSApp.terminate(nil)
                    }
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    let name = self.player.nowPlayingTrackID.flatMap { id in Library.shared.playlists.flatMap(\.tracks).first { $0.id == id }?.displayName } ?? "-"
                    print(String(format: "after restart: track=%@ t=%.1f playing=%@  (saved point cleared: %@)", name, self.player.debugCurrentTime, self.player.debugIsPlaying ? "yes" : "no",
                                 UserDefaults.standard.dictionary(forKey: "resumePoint") == nil ? "yes" : "no"))
                    fflush(stdout); NSApp.terminate(nil)
                }
            }
        }
        if let clip = ProcessInfo.processInfo.environment["REEL_AUTOCLOSE_TEST"] {
            let pl = self.player!
            let pb = NSPasteboard(name: NSPasteboard.Name("reel-ac-\(getpid())")); pb.clearContents(); pb.writeObjects([URL(fileURLWithPath: clip) as NSURL])
            let ia = pl.debugInteraction
            let steps: [(Double, () -> Void)] = [
                (1.0, { _ = ia.onDragEnter?(pb); print("A. drag over video → playlist open: \(pl.panelOpen)") }),
                (0.6, { ia.onDragExit?(); _ = ia.onDrop?(pb); print("   dropped on video") }),
                (1.5, { print("   1.5 s after drop → open: \(pl.panelOpen)  (showing where it went)") }),
                (2.0, { print("   3.5 s after drop → open: \(pl.panelOpen)  (closed again)") }),
                (0.5, { _ = ia.onDragEnter?(pb); print("B. drag over video → open: \(pl.panelOpen)") }),
                (0.6, { ia.onDragExit?(); print("   dragged away without dropping") }),
                (1.8, { print("   1.8 s later → open: \(pl.panelOpen)  (closed again)") }),
                (0.3, { pl.togglePlaylist(); print("C. opened by you → open: \(pl.panelOpen)") }),
                (0.6, { _ = pl.panel.acceptExternal(pb, at: nil, playFirst: false); print("   pasted a file") }),
                (3.5, { print("   3.5 s later → open: \(pl.panelOpen)  (stays open — you opened it)"); pb.releaseGlobally(); fflush(stdout); NSApp.terminate(nil) }),
            ]
            var t = 0.0
            for (d, f) in steps { t += d; DispatchQueue.main.asyncAfter(deadline: .now() + t) { f(); fflush(stdout) } }
        }
        if ProcessInfo.processInfo.environment["REEL_WRAP_TEST"] != nil {
            let pl = self.player!, panel = pl.panel
            func playing() -> String { pl.nowPlayingTrackID.flatMap { id in panel.tracks.first { $0.id == id }?.displayName } ?? "-" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                print("playlist:", panel.tracks.map(\.displayName), " playing:", playing())
                pl.panelPlay(playlist: panel.shownID, track: panel.tracks.last!.id)
                print("on the last track (\(playing())), loop off, waiting for it to end…"); fflush(stdout)
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                    print("after it ended: playing \(playing()) (\(pl.debugIsPlaying ? "playing" : "stopped"))")
                    pl.panelPlay(playlist: panel.shownID, track: panel.tracks.last!.id); pl.nextTrack()
                    print("↓ on the last track: \(playing())"); fflush(stdout); NSApp.terminate(nil)
                }
            }
        }
        if ProcessInfo.processInfo.environment["REEL_FIRSTRUN_TEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                print("help window visible: \(NSApp.windows.contains { $0.title == "Reel Help" && $0.isVisible })"); fflush(stdout)
                NSApp.terminate(nil)
            }
        }
        if ProcessInfo.processInfo.environment["REEL_AUTOPLAY_TEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                print(String(format: "3s after launch: playing=%@ t=%.2f", self.player.debugIsPlaying ? "yes" : "no", self.player.debugCurrentTime)); fflush(stdout)
                NSApp.terminate(nil)
            }
        }
        if ProcessInfo.processInfo.environment["REEL_SPACE_TEST"] != nil {
            NSApp.activate(ignoringOtherApps: true)
            self.player.window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let w = self.player.window
                for (label, setup) in [("video focused", { _ = w.makeFirstResponder(w.contentView) }),
                                       ("after clicking a playlist button", { self.player.setPanel(open: true); _ = w.makeFirstResponder(self.player.panel.table) })] as [(String, () -> Void)] {
                    setup()
                    let before = self.player.debugToggleCount
                    let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
                    let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
                    NSApp.sendEvent(down); NSApp.sendEvent(up)
                    print("space (\(label), key=\(w.isKeyWindow), first responder \(type(of: w.firstResponder!))): togglePlay ran \(self.player.debugToggleCount - before)x"); fflush(stdout)
                }
                NSApp.terminate(nil)
            }
        }
        if ProcessInfo.processInfo.environment["REEL_FIT_TEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                print("before fit: \(self.player.window.frame) screen \(self.player.window.screen?.visibleFrame ?? .zero)"); fflush(stdout)
                self.player.menuActualAspect(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { print("after fit: \(self.player.window.frame)"); fflush(stdout); NSApp.terminate(nil) }
            }
        }
        if ProcessInfo.processInfo.environment["REEL_FIRSTCLICK_TEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let w = self.player.window
                let video = w.contentView!.subviews.first!
                let p = video.convert(NSPoint(x: video.bounds.midX, y: video.bounds.midY), to: nil)
                let before = self.player.debugIsPlaying
                let down = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                let up = NSEvent.mouseEvent(with: .leftMouseUp, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
                w.sendEvent(down); w.sendEvent(up)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    print("unfocused (key=\(w.isKeyWindow)) click on video: playing \(before) -> \(self.player.debugIsPlaying)"); fflush(stdout); NSApp.terminate(nil)
                }
            }
        }
        if let dir = ProcessInfo.processInfo.environment["REEL_IO_TEST"] {
            let pl = self.player!, panel = pl.panel
            pl.setPanel(open: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let src = Library.shared.playlist(panel.shownID)!
                let out = URL(fileURLWithPath: dir + "/slim.json")
                try! panel.exportData(src).write(to: out)
                print("exported \(src.tracks.count) tracks")
                panel.add(files: [out], at: nil)
                let imp = Library.shared.playlist(panel.shownID)!
                print("imported '\(imp.name)':")
                for t in imp.tracks { print("  \(t.kind.rawValue) | \(t.displayName) | loop=\(t.loop) skip=\(t.isSkipped) available=\(t.isAvailable) | \(t.source)") }
                // the moved file: relink one, and the folder-mate gets fixed too
                let missing = imp.tracks.filter { !$0.isAvailable }
                if let first = missing.first {
                    let n = panel.relink(first.id, to: URL(fileURLWithPath: dir + "/moved/" + first.url!.lastPathComponent.removingPercentEncoding!))
                    print("relinked '\(first.displayName)' + \(n) other(s); still missing: \(Library.shared.playlist(panel.shownID)!.tracks.filter { !$0.isAvailable }.count)")
                }
                // play the imported Bilibili entry (needs the part-id lookup)
                if let bb = Library.shared.playlist(panel.shownID)!.tracks.first(where: { $0.kind == .bilibili }) {
                    pl.panelPlay(playlist: panel.shownID, track: bb.id)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                    print(String(format: "bilibili after import: t=%.1f", pl.debugCurrentTime)); fflush(stdout); NSApp.terminate(nil)
                }
                fflush(stdout)
            }
        }
        if ProcessInfo.processInfo.environment["REEL_DISMISS_TEST"] != nil {
            // A click that only closes a popup (icon menu, rename) must not also play/pause or pick a track.
            let pl = self.player!, panel = pl.panel, table = panel.table, w = pl.window
            pl.setPanel(open: true)
            func click(_ p: NSPoint, right: Bool = false) {   // through NSApp, so event monitors see it like a real click
                let (d, u): (NSEvent.EventType, NSEvent.EventType) = right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
                func ev(_ t: NSEvent.EventType) -> NSEvent {
                    NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: t == d ? 1 : 0)!
                }
                if right { NSApp.sendEvent(ev(d)); NSApp.sendEvent(ev(u)) }
                else { NSApp.postEvent(ev(u), atStart: true); NSApp.sendEvent(ev(d)) }   // queued up-event lets the table's tracking loop finish

            }
            func videoPoint() -> NSPoint { let v = w.contentView!.subviews.first!; return v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.midY), to: nil) }
            func rowPoint(_ r: Int) -> NSPoint { let rr = table.rect(ofRow: r); return table.convert(NSPoint(x: rr.midX, y: rr.midY), to: nil) }
            func state() -> String {
                let name = pl.nowPlayingTrackID.flatMap { id in panel.tracks.first { $0.id == id }?.displayName } ?? "-"
                return "playing=\(pl.debugIsPlaying) track='\(name)'"
            }
            func later(_ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { f(); fflush(stdout) } }
            var steps: [() -> Void] = []
            steps.append { print("start: \(state())") }
            steps.append { click(videoPoint(), right: true); later { print("right-click video → icon menu showing=\(IconMenu.shared.isShowing)") } }
            steps.append { click(videoPoint()); later { print("click video to dismiss → menu showing=\(IconMenu.shared.isShowing), \(state())") } }
            steps.append { click(rowPoint(1), right: true); later { print("right-click row 1 → icon menu showing=\(IconMenu.shared.isShowing)") } }
            steps.append { click(rowPoint(2)); later { print("click row 2 to dismiss → menu showing=\(IconMenu.shared.isShowing), \(state())") } }
            steps.append {
                (table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? TrackCell)?.title.beginRename()
                print("renaming row 1: \((table.view(atColumn: 0, row: 1, makeIfNecessary: false) as? TrackCell)?.title.editingName ?? false)")
            }
            steps.append {
                click(videoPoint())
                later { print("click video to finish rename → renaming=\((table.view(atColumn: 0, row: 1, makeIfNecessary: false) as? TrackCell)?.title.editingName ?? false), \(state())") }
            }
            steps.append { click(videoPoint()); later { print("ordinary click on video still toggles → \(state())") } }
            steps.append { click(rowPoint(2)); later { print("ordinary click on row 2 still plays → \(state())") } }
            for (i, st) in steps.enumerated() { DispatchQueue.main.asyncAfter(deadline: .now() + 2.0 + Double(i) * 0.7) { st(); fflush(stdout) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5 + Double(steps.count) * 0.7) { NSApp.terminate(nil) }
        }
        if let dir = ProcessInfo.processInfo.environment["REEL_DROP_TEST"] {
            // Drag-over outlines and the "Added …" message, with window screenshots in `dir`.
            // (A real drag can't be synthesized, so this calls the same handlers the drag does.)
            let pl = self.player!, panel = pl.panel, w = pl.window
            let files = (ProcessInfo.processInfo.environment["REEL_DROP_FILES"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
            func pb(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
                let p = NSPasteboard(name: NSPasteboard.Name("reel-drop-test-\(getpid())-\(UUID().uuidString)")); p.clearContents(); fill(p); return p
            }
            func snap(_ name: String) {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-o", "-l\(w.windowNumber)", dir + "/" + name + ".png"]; try? p.run(); p.waitUntilExit()
            }
            let enter = { (p: NSPasteboard) -> Bool in
                // same closure InteractionView.draggingEntered calls
                let v = w.contentView!.subviews.first!.subviews.compactMap { $0 as? InteractionView }.first!
                return v.onDragEnter?(p) ?? false
            }
            pl.setPanel(open: true)
            var steps: [() -> Void] = []
            steps.append {
                let ok = enter(pb { $0.writeObjects(files as [NSURL]) })
                print("drag \(files.count) files over video: accepted=\(ok) shows '\(pl.dropHighlight.title)' / '\(pl.dropHighlight.detail)'")
            }
            steps.append { snap("1-video-drag"); pl.dropHighlight.hide()
                let ok = panel.showDropHighlight(pb { $0.setString("https://www.youtube.com/watch?v=dQw4w9WgXcQ", forType: .string) })
                print("drag a link over playlist: accepted=\(ok) shows '\(panel.dropHighlight.title)' / '\(panel.dropHighlight.detail)'")
            }
            steps.append { snap("2-panel-drag"); panel.dropHighlight.hide()
                let ok = enter(pb { $0.setString("just some words", forType: .string) })
                print("drag plain text over video: accepted=\(ok) highlight showing=\(pl.dropHighlight.isShowing)")
            }
            steps.append {
                panel.acceptExternal(pb { $0.writeObjects(Array(files.prefix(2)) as [NSURL]) }, at: nil)
                print("drop 2 files (while playing): toast '\(pl.toast.text)', selected rows \(Array(panel.table.selectedRowIndexes))")
            }
            steps.append { snap("3-added-toast")
                let gp = NSPasteboard.general; let saved = gp.string(forType: .string)
                gp.clearContents(); gp.setString("nothing useful here", forType: .string)
                pl.paste(nil)
                print("⌘V with plain text: toast '\(pl.toast.text)'")
                gp.clearContents(); if let saved { gp.setString(saved, forType: .string) }
            }
            steps.append {
                panel.add(text: "https://example.com/a/clip.mp4 https://example.com/b/other.mp4", at: nil)
                print("paste 2 links: toast right away '\(pl.toast.text)'")
            }
            steps.append { print("…then '\(pl.toast.text)'"); snap("4-links-toast") }
            for (i, st) in steps.enumerated() { DispatchQueue.main.asyncAfter(deadline: .now() + 2.0 + Double(i) * 1.0) { st(); fflush(stdout) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5 + Double(steps.count) * 1.0) { NSApp.terminate(nil) }
        }
        if ProcessInfo.processInfo.environment["REEL_VOLUME_TEST"] != nil {
            // The % is a perceptual level; the player gets a decibel-scaled gain.
            for p: Float in [1, 0.9, 0.75, 0.5, 0.25, 0.1, 0.05, 0.02, 0] {
                let g = Loudness.gain(p)
                print(String(format: "level %3.0f%% -> gain %.4f (%@)", p * 100, g, g > 0 ? String(format: "%.1f dB", 20 * log10f(g)) : "silent"))
            }
            for g: Float in [1, 0.5, 0.25, 0.1] {
                print(String(format: "old saved gain %.2f -> shows %.0f%%, plays at gain %.4f", g, Loudness.level(forGain: g) * 100, Loudness.gain(Loudness.level(forGain: g))))
            }
            let pl = self.player!
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                print(String(format: "playing at level %.0f%%: player gain %.4f", pl.debugVolumeLevel * 100, pl.debugPlayerGain))
                for _ in 0..<10 { pl.debugScrollVolume(-1) }   // 10 wheel notches down = -50%
                print(String(format: "10 notches down: level %.0f%%, player gain %.4f (%.1f dB)", pl.debugVolumeLevel * 100, pl.debugPlayerGain, 20 * log10f(pl.debugPlayerGain)))
                fflush(stdout); NSApp.terminate(nil)
            }
        }
        if ProcessInfo.processInfo.environment["REEL_ABOUT_TEST"] != nil {
            AboutWindow.shared.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { NSApp.terminate(nil) }
        }
        if ProcessInfo.processInfo.environment["REEL_HELP_TEST"] != nil {
            HelpWindow.shared.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { NSApp.terminate(nil) }
        }
        if ProcessInfo.processInfo.environment["REEL_PANEL_TEST"] == "resize" {
            let w = player.window
            func log(_ s: String) { print(s, w.frame); fflush(stdout) }
            log("start")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.player.setPanel(open: true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                log("opened")
                // user resizes while open (through the real resize rule)
                let sz = self.player.windowWillResize(w, to: NSSize(width: w.frame.width + 200, height: w.frame.height + 150))
                w.setFrame(NSRect(origin: NSPoint(x: w.frame.minX, y: w.frame.maxY - sz.height), size: sz), display: true)
                let tooShort = self.player.windowWillResize(w, to: NSSize(width: w.frame.width, height: 120))
                log("resized while open (asking for 120 tall gives \(Int(tooShort.width))x\(Int(tooShort.height)))")
                self.player.setPanel(open: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { log("closed"); NSApp.terminate(nil) }
        } else if ProcessInfo.processInfo.environment["REEL_PANEL_TEST"] != nil {
            let w = player.window
            func log(_ s: String) { print(s, w.frame, "screen", w.screen?.visibleFrame ?? .zero); fflush(stdout) }
            log("start")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.player.setPanel(open: true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { log("opened") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { self.player.setPanel(open: false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { log("closed"); NSApp.terminate(nil) }
        }
    }

    func application(_ app: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        if player == nil { pendingOpen += files } else { player.open(files: files) }
    }

    @objc func showHelp(_ sender: Any?) { HelpWindow.shared.show() }

    /// Fresh install → open Reel Help once on first launch. Existing users (they already have a saved
    /// library or window position) never see it, even right after updating to this version.
    private func showWelcomeIfFreshInstall() {
        let d = UserDefaults.standard
        let env = ProcessInfo.processInfo.environment
        let fresh = !d.bool(forKey: "seenWelcome") && !Library.shared.existedAtLaunch && d.object(forKey: "videoFrame") == nil
        let testing = env.keys.contains { $0.hasPrefix("REEL_") } && env["REEL_FIRSTRUN_TEST"] == nil
        guard !testing else { return }
        d.set(true, forKey: "seenWelcome")
        guard fresh else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            HelpWindow.shared.show()
            if env["REEL_FIRSTRUN_TEST"] != nil { print("welcome: Help shown"); fflush(stdout) }
        }
    }
    @objc func showAbout(_ sender: Any?) { AboutWindow.shared.show() }
    @objc func checkForUpdates(_ sender: Any?) {
        Task { @MainActor in await Updater.check(interactive: true, window: self.player.window) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) { player.saveState() }

    private func buildMenu() {
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            top.submenu = m
            main.addItem(top)
        }
        func item(_ t: String, _ a: Selector?, _ k: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            return i
        }
        menu("Reel", [
            { let i = item("About Reel", #selector(AppDelegate.showAbout(_:))); i.target = self; return i }(),
            { let i = item("Check for Updates…", #selector(AppDelegate.checkForUpdates(_:))); i.target = self; return i }(),
            .separator(),
            item("Hide Reel", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Reel", #selector(NSApplication.terminate(_:)), "q"),
        ])
        menu("File", [
            item("Open…", #selector(PlayerController.openDocument(_:)), "o"),
            item("New Playlist", #selector(PlayerController.newPlaylist(_:)), "n"),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ])
        menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        menu("Playback", [
            // Plain keys (Space, arrows) are handled once by the player's key handler; giving these
            // menu items the same keys made every press fire twice.
            item("Play / Pause    Space", #selector(PlayerController.menuTogglePlay(_:))),
            item("Forward 10 Seconds    →", #selector(PlayerController.menuSkipFwd(_:))),
            item("Back 10 Seconds    ←", #selector(PlayerController.menuSkipBack(_:))),
            item("Next Track    ↓", #selector(PlayerController.menuNext(_:))),
            item("Previous Track    ↑", #selector(PlayerController.menuPrev(_:))),
            .separator(),
            item("Loop This Track", #selector(PlayerController.menuLoop(_:)), "l"),
            item("Mute", #selector(PlayerController.menuMute(_:)), "m", [.command, .shift]),
        ])
        menu("View", [
            item("Show Playlist", #selector(PlayerController.menuPlaylist(_:)), "p"),
            item("Always on Top", #selector(PlayerController.menuPin(_:)), "t"),
            item("Actual Size (or Fit Screen)", #selector(PlayerController.menuActualAspect(_:)), "0"),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        let wm = NSMenuItem(title: "Window", action: nil, keyEquivalent: ""); wm.submenu = windowMenu
        main.addItem(wm)
        NSApp.windowsMenu = windowMenu
        let helpMenu = NSMenu(title: "Help")
        let helpItem = NSMenuItem(title: "Reel Help", action: #selector(AppDelegate.showHelp(_:)), keyEquivalent: "?")
        helpItem.target = self
        helpMenu.addItem(helpItem)
        let hm = NSMenuItem(title: "Help", action: nil, keyEquivalent: ""); hm.submenu = helpMenu
        main.addItem(hm)
        NSApp.helpMenu = helpMenu
        NSApp.mainMenu = main
    }
}

// Debug: REEL_RESOLVE="<url>" prints what a URL expands to, then exits.
if let u = ProcessInfo.processInfo.environment["REEL_RESOLVE"] {
    let sem = DispatchSemaphore(value: 0)
    Task {
        let ts = await MediaResolver.tracks(forText: u)
        print("resolved \(ts.count) tracks")
        for t in ts.prefix(8) { print(" -", t.kind.rawValue, t.source, "|", t.autoTitle, "|", t.duration ?? 0) }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

// Let AVFoundation decode VP9 (and AV1 where the Mac supports it) — e.g. VP9 inside .mp4 files,
// which otherwise play as sound over a black picture. Safari does the same.
VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
if #available(macOS 14.0, *) { VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
