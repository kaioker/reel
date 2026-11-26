import AppKit
import ApplicationServices

/// Reel's hotkeys while the mouse is over the player — even when another app is active.
///
/// macOS only delivers key presses to the active app, so this uses an event tap (needs the Accessibility
/// permission). It steps in only when ALL of these hold: Reel isn't the active app, the pointer is over
/// Reel's window (and Reel is the top window there), and the key is one of Reel's hotkeys: a plain key
/// (⇧ allowed, except on arrows) or ⌘ with an arrow. Then Reel acts on it and swallows it, so e.g. Space doesn't also type into the
/// app you're in. Every other key passes through untouched.
final class HoverHotkeys {
    private weak var player: PlayerController?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retry: Timer?

    init(player: PlayerController) { self.player = player }

    var isActive: Bool { tap != nil }
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Starts now if permitted; otherwise starts as soon as the permission is granted.
    func start() {
        if debugLog { print("hover: start, trusted=\(HoverHotkeys.isTrusted)"); fflush(stdout) }
        if install() { return }
        // not allowed yet: keep checking quietly and switch on once it is (asking is done by the setting)
        retry?.invalidate()
        retry = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
            if self?.install() == true { t.invalidate() }
        }
    }

    /// Shows the system prompt that links to Privacy & Security → Accessibility.
    func askForPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @discardableResult
    private func install() -> Bool {
        guard tap == nil else { return true }
        guard HoverHotkeys.isTrusted else { return false }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        if debugLog { print("hover: creating tap"); fflush(stdout) }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: hoverTapCallback, userInfo: me) else {
            if debugLog { print("hover: tapCreate returned nil"); fflush(stdout) }
            return false
        }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        if debugLog { print("hover hotkeys: active"); fflush(stdout) }
        return true
    }

    /// Turns hover hotkeys off completely (removes the event tap).
    func stop() {
        retry?.invalidate(); retry = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }

    fileprivate func reenable() { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }

    /// The decision, separated out so it can be tested without a real tap.
    static func shouldHandle(keyCode: UInt16, flags: CGEventFlags, reelIsActive: Bool, pointerOverPlayer: Bool) -> Bool {
        guard !reelIsActive, pointerOverPlayer else { return false }
        if flags.contains(.maskControl) || flags.contains(.maskAlternate) { return false }
        let arrow = (123...126).contains(keyCode)
        if flags.contains(.maskCommand) { return arrow && !flags.contains(.maskShift) }   // ⌘-arrows: tracks / playlists
        if arrow && flags.contains(.maskShift) { return false }                           // ⇧-arrows stay with the other app
        return hotkeyCodes.contains(keyCode)
    }

    /// Reel's hotkeys by key position: Space, ← → ↑ ↓, Esc, F, L, M, S, V, [ ] =, , .
    static let hotkeyCodes: Set<UInt16> = [49, 123, 124, 125, 126, 53, 3, 37, 46, 1, 9, 33, 30, 24, 43, 47]

    /// Runs on the main thread (the tap's run-loop source is on the main run loop).
    fileprivate func handle(_ event: CGEvent) -> Bool {
        guard let player else { return false }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        // REEL_DEBUG only: the tap sees every key on the Mac, so log just Reel's hotkeys pressed with the
        // pointer over Reel's window — never ordinary typing in other apps.
        if debugLog, HoverHotkeys.hotkeyCodes.contains(code), player.window.frame.contains(NSEvent.mouseLocation) {
            let pt = NSEvent.mouseLocation
            print("hover key \(code): reelActive=\(NSApp.isActive) over=\(player.isPointerOverPlayer()) inFrame=\(player.window.frame.contains(pt)) topWindow=\(NSWindow.windowNumber(at: pt, belowWindowWithWindowNumber: 0)) reelWindow=\(player.window.windowNumber) visible=\(player.window.isVisible)")
            fflush(stdout)
        }
        guard HoverHotkeys.shouldHandle(keyCode: code, flags: event.flags, reelIsActive: NSApp.isActive,
                                        pointerOverPlayer: player.isPointerOverPlayer()) else { return false }
        // letters by key position, so F / L / M work even if the event carries no characters
        let byPosition: [UInt16: String] = [3: "f", 37: "l", 46: "m", 1: "s", 9: "v", 33: "[", 30: "]", 24: "=", 43: ",", 47: "."]
        let chars = NSEvent(cgEvent: event)?.charactersIgnoringModifiers.flatMap { $0.isEmpty ? nil : $0 } ?? byPosition[code]
        let did = player.performHotkey(keyCode: code, command: event.flags.contains(.maskCommand),
                                     shift: event.flags.contains(.maskShift), chars: chars)
        if did { HoverHotkeys.handledCount += 1 }
        return did
    }
    static var handledCount = 0     // for the self-test
}

private func hoverTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let me = Unmanaged<HoverHotkeys>.fromOpaque(userInfo).takeUnretainedValue()
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if debugLog { print("hover: tap was switched off by macOS (\(type == .tapDisabledByTimeout ? "timeout" : "user input")); turning it back on"); fflush(stdout) }
        me.reenable()                               // macOS switches slow taps off; turn it back on
        return Unmanaged.passUnretained(event)
    case .keyDown:
        return me.handle(event) ? nil : Unmanaged.passUnretained(event)   // nil = swallowed
    default:
        return Unmanaged.passUnretained(event)
    }
}
