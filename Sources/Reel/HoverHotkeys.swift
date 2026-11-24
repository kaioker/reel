import AppKit
import ApplicationServices

/// Reel's hotkeys while the mouse is over the player — even when another app is active.
///
/// macOS only delivers key presses to the active app, so this uses an event tap (needs the Accessibility
/// permission). It steps in only when ALL of these hold: Reel isn't the active app, the pointer is over
/// Reel's window (and Reel is the top window there), the key is one of Reel's hotkeys, and no modifier
/// other than ⇧ is held. Then Reel acts on it and swallows it, so e.g. Space doesn't also type into the
/// app you're in. Every other key passes through untouched.
final class HoverHotkeys {
    private weak var player: PlayerController?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retry: Timer?

    init(player: PlayerController) { self.player = player }

    var isActive: Bool { tap != nil }
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Starts now if permitted; otherwise asks once (System Settings) and starts when it's granted.
    func start() {
        if debugLog { print("hover: start, trusted=\(HoverHotkeys.isTrusted)"); fflush(stdout) }
        if install() { return }
        let d = UserDefaults.standard
        if !d.bool(forKey: "askedHoverHotkeysPermission") {
            d.set(true, forKey: "askedHoverHotkeysPermission")
            askForPermission()
        }
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

    fileprivate func reenable() { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }

    /// The decision, separated out so it can be tested without a real tap.
    static func shouldHandle(keyCode: UInt16, flags: CGEventFlags, reelIsActive: Bool, pointerOverPlayer: Bool) -> Bool {
        guard !reelIsActive, pointerOverPlayer else { return false }
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) { return false }
        // Reel's hotkeys: Space, ← → ↑ ↓, Esc, F, L, M (by key position)
        return [49, 123, 124, 125, 126, 53, 3, 37, 46].contains(keyCode)
    }

    /// Runs on the main thread (the tap's run-loop source is on the main run loop).
    fileprivate func handle(_ event: CGEvent) -> Bool {
        guard let player else { return false }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard HoverHotkeys.shouldHandle(keyCode: code, flags: event.flags, reelIsActive: NSApp.isActive,
                                        pointerOverPlayer: player.isPointerOverPlayer()) else { return false }
        let chars = NSEvent(cgEvent: event)?.charactersIgnoringModifiers
        return player.performHotkey(keyCode: code, shift: event.flags.contains(.maskShift), chars: chars)
    }
}

private func hoverTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let me = Unmanaged<HoverHotkeys>.fromOpaque(userInfo).takeUnretainedValue()
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        me.reenable()                               // macOS switches slow taps off; turn it back on
        return Unmanaged.passUnretained(event)
    case .keyDown:
        return me.handle(event) ? nil : Unmanaged.passUnretained(event)   // nil = swallowed
    default:
        return Unmanaged.passUnretained(event)
    }
}
