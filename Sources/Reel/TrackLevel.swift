import AVFoundation
import Accelerate
import MediaToolbox

/// A track's own volume, relative to Reel's volume: +/- dB, so a loud track on an album can be levelled against the
/// rest. Reel's volume stays the one control for everything; a track's level is applied on top of it while it plays.
/// Below full volume it's just a lower gain; above it (a quiet track turned up while Reel is at 100%) the samples
/// themselves are amplified, with a soft limit so peaks bend instead of clipping.
enum TrackLevel {
    static let range: ClosedRange<Double> = -24...12
    /// What the track-volume menu offers (finer steps with ⌥⌘↑ / ⌥⌘↓).
    static let presets: [Double] = [12, 9, 6, 4, 3, 2, 1, 0, -1, -2, -3, -4, -6, -9, -12, -18, -24]

    static func clamp(_ db: Double) -> Double { (min(range.upperBound, max(range.lowerBound, db)) * 2).rounded() / 2 }

    /// "+3 dB", "−4.5 dB" (a real minus sign), "0 dB".
    static func label(_ db: Double) -> String {
        let n = abs(db).truncatingRemainder(dividingBy: 1) == 0 ? String(Int(abs(db))) : String(format: "%.1f", abs(db))
        return db > 0 ? "+\(n) dB" : db < 0 ? "−\(n) dB" : "0 dB"
    }

    /// dB → amplitude factor.
    static func factor(_ db: Double) -> Float { powf(10, Float(db) / 20) }

    // MARK: Amplifying (gain above 1)

    /// From here up, peaks are bent rather than clipped (about −1 dBFS).
    private static let knee: Float = 0.89

    /// Multiplies `count` float samples by `gain` (> 1), softly limiting anything that would pass the knee.
    static func amplify(_ p: UnsafeMutablePointer<Float>, count: Int, gain: Float) {
        guard gain > 1.0001, count > 0 else { return }
        var g = gain
        vDSP_vsmul(p, 1, &g, p, 1, vDSP_Length(count))
        let room = 1 - knee
        for i in 0..<count {
            let x = p[i], a = abs(x)
            if a > knee { p[i] = copysignf(knee + room * tanhf((a - knee) / room), x) }
        }
    }

    // MARK: macOS's player: an audio processing tap

    /// Shared with the tap on the audio thread: the gain (≥ 1) and whether the audio is 32-bit float (it can
    /// only amplify that; anything else passes through untouched).
    final class TapState {
        var gain: Float = 1
        var isFloat = false
        /// Loudest sample after amplifying, since the last read (tests).
        var peak: Float = 0
    }

    /// An audio mix that runs `track`'s audio through `state`'s gain. Nil if macOS won't make the tap.
    static func mix(for track: AVAssetTrack, state: TapState) -> AVAudioMix? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(state).toOpaque(),
            init: { _, clientInfo, storageOut in
                // the tap keeps the state alive until it's finalized
                storageOut.pointee = clientInfo.map { Unmanaged<TapState>.fromOpaque($0).retain().toOpaque() }
            },
            finalize: { tap in
                Unmanaged<TapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let s = Unmanaged<TapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let f = format.pointee
                s.isFloat = f.mFormatFlags & kAudioFormatFlagIsFloat != 0 && f.mBitsPerChannel == 32
            },
            unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr else { return }
                let s = Unmanaged<TapState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let g = s.gain
                guard s.isFloat, g > 1.0001 else { return }
                for b in UnsafeMutableAudioBufferListPointer(buffers) {
                    guard let data = b.mData else { continue }
                    let n = Int(b.mDataByteSize) / MemoryLayout<Float>.size
                    let p = data.assumingMemoryBound(to: Float.self)
                    TrackLevel.amplify(p, count: n, gain: g)
                    var m: Float = 0
                    vDSP_maxmgv(p, 1, &m, vDSP_Length(n))
                    if m > s.peak { s.peak = m }
                }
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr,
              let tap else { return nil }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }
}
