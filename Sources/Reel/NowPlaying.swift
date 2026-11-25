import AppKit
import MediaPlayer

/// Headset buttons, AirPods taps and the keyboard's media keys (⏯ ⏭ ⏮) go to whichever app macOS considers
/// "Now Playing". Reel registers its commands here and keeps the Now Playing info (title, length, position)
/// current, which is also what Control Center's Now Playing shows.
final class NowPlaying {
    struct Actions {
        var play: () -> Void
        var pause: () -> Void
        var toggle: () -> Void
        var next: () -> Void
        var previous: () -> Void
        var skip: (Double) -> Void
        var seek: (Double) -> Void
    }

    private let center = MPRemoteCommandCenter.shared()
    private let info = MPNowPlayingInfoCenter.default()
    private var lastPush = Date.distantPast
    private lazy var artwork: MPMediaItemArtwork? = {
        guard let icon = NSApp.applicationIconImage else { return nil }
        return MPMediaItemArtwork(boundsSize: NSSize(width: 512, height: 512)) { _ in icon }
    }()

    let actions: Actions   // kept for tests
    /// Playback speed, so Control Center's position moves at the right pace.
    var speed: Double = 1
    init(_ a: Actions) {
        actions = a
        center.playCommand.addTarget { _ in a.play(); return .success }
        center.pauseCommand.addTarget { _ in a.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { _ in a.toggle(); return .success }
        center.nextTrackCommand.addTarget { _ in a.next(); return .success }
        center.previousTrackCommand.addTarget { _ in a.previous(); return .success }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { e in a.skip((e as? MPSkipIntervalCommandEvent)?.interval ?? 10); return .success }
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.addTarget { e in a.skip(-((e as? MPSkipIntervalCommandEvent)?.interval ?? 10)); return .success }
        center.changePlaybackPositionCommand.addTarget { e in
            guard let p = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            a.seek(p.positionTime); return .success
        }
        for c in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.nextTrackCommand,
                  center.previousTrackCommand, center.changePlaybackPositionCommand] { c.isEnabled = true }
        // Left off on purpose: with ±10 s skip commands enabled, macOS can show ±10 s in place of ⏭ ⏮ and some
        // headsets' forward/back would skip time instead of changing track. (← / → still skip 10 s.)
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
    }

    /// Call when the track, play state or position changes. Cheap to call often (throttled unless `force`).
    func update(title: String?, album: String?, duration: Double, elapsed: Double, playing: Bool, force: Bool = false) {
        if !force && Date().timeIntervalSince(lastPush) < 1 { return }
        lastPush = Date()
        guard let title else {
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
            return
        }
        var d: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Reel",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, elapsed),
            MPNowPlayingInfoPropertyPlaybackRate: playing ? speed : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if let album { d[MPMediaItemPropertyAlbumTitle] = album }
        if duration > 0 { d[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork { d[MPMediaItemPropertyArtwork] = artwork }
        info.nowPlayingInfo = d
        info.playbackState = playing ? .playing : .paused
    }

    // for tests
    var debugInfo: [String: Any]? { info.nowPlayingInfo }
    var debugState: MPNowPlayingPlaybackState { info.playbackState }
}
