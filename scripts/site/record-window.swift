// Records one app's window (nothing else on screen) as PNG frames with transparency, for the website's GIFs.
//   swiftc -O scripts/site/record-window.swift -o .build/record-window
//   .build/record-window <pid> <seconds> <out-folder> [fps] [--screen]
// Uses ScreenCaptureKit with only that app's windows, so the desktop and other apps never appear in the frames.
// Default: the one window, at its size. --screen: the app's windows where they are on their display (for a
// window that grows or moves); everything else is transparent — crop the frames to what's used afterwards.
import AppKit
import CoreImage
import ScreenCaptureKit

let args = CommandLine.arguments
guard args.count >= 4, let pid = Int32(args[1]), let seconds = Double(args[2]) else {
    print("usage: record-window <pid> <seconds> <out-folder> [fps]"); exit(2)
}
let out = URL(fileURLWithPath: args[3], isDirectory: true)
let fps = args.count > 4 ? (Int32(args[4]) ?? 30) : 30
let wholeScreen = args.contains("--screen")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

final class Recorder: NSObject, SCStreamOutput {
    let ci = CIContext()
    var n = 0
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid, let pb = sb.imageBuffer else { return }
        // skip frames ScreenCaptureKit marks as unchanged / not complete
        if let att = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
           let raw = att[.status] as? Int, let st = SCFrameStatus(rawValue: raw), st != .complete { return }
        let img = CIImage(cvPixelBuffer: pb)
        guard let cg = ci.createCGImage(img, from: img.extent) else { return }
        n += 1
        let url = out.appendingPathComponent(String(format: "f%05d.png", n))
        if let d = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) { try? d.write(to: url) }
    }
}

let rec = Recorder()
Task { do {
    // wait for the app's window
    var window: SCWindow?
    for _ in 0..<100 {
        if let c = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) {
            window = c.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer < 100 && $0.frame.width > 120 }
                .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        }
        if window != nil { break }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    guard let window else { print("no window for pid \(pid)"); exit(1) }
    let cfg = SCStreamConfiguration()
    let filter: SCContentFilter
    if wholeScreen {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.frame.intersects(window.frame) }) else { print("no display"); exit(1) }
        let mine = content.windows.filter { $0.owningApplication?.processID == pid }
        filter = SCContentFilter(display: display, including: mine)
        cfg.width = Int(CGFloat(display.width) * CGFloat(filter.pointPixelScale))
        cfg.height = Int(CGFloat(display.height) * CGFloat(filter.pointPixelScale))
        cfg.backgroundColor = .clear
    } else {
        filter = SCContentFilter(desktopIndependentWindow: window)
        cfg.width = Int(window.frame.width * CGFloat(filter.pointPixelScale))
        cfg.height = Int(window.frame.height * CGFloat(filter.pointPixelScale))
    }
    let scale = CGFloat(filter.pointPixelScale)
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: fps)
    cfg.pixelFormat = kCVPixelFormatType_32BGRA
    cfg.showsCursor = false
    cfg.ignoreShadowsSingleWindow = true
    cfg.shouldBeOpaque = false
    let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
    try stream.addStreamOutput(rec, type: .screen, sampleHandlerQueue: DispatchQueue(label: "frames"))
    try await stream.startCapture()
    print("recording \(Int(window.frame.width))x\(Int(window.frame.height)) pt at \(scale)x"); fflush(stdout)
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    try? await stream.stopCapture()
    print("\(rec.n) frames → \(out.path)")
    exit(0)
} catch { print("recording failed: \(error)"); exit(1) } }
RunLoop.main.run()
