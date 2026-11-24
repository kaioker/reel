// Builds Design/ReelPlaylist.icns — the Finder icon for .reel playlist files: a white page with a folded
// corner, Reel's icon in the middle and "REEL" along the bottom (the look of macOS document icons).
//   swiftc -O scripts/make-doc-icon.swift -o .build/make-doc-icon && .build/make-doc-icon
// Run scripts/make-icon.swift first (it makes Design/AppIcon-1024.png).
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let appIcon = NSImage(contentsOf: root.appendingPathComponent("Design/AppIcon-1024.png"))!
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func render(_ px: Int) -> CGImage {
    let S = CGFloat(px), k = S / 1024
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // page: 820 tall × 640 wide on the 1024 grid, folded top-right corner
    let page = CGRect(x: 192 * k, y: 60 * k, width: 640 * k, height: 904 * k)
    let fold = 170 * k, r = 36 * k
    let path = CGMutablePath()
    path.move(to: CGPoint(x: page.minX + r, y: page.minY))
    path.addLine(to: CGPoint(x: page.maxX - r, y: page.minY))
    path.addQuadCurve(to: CGPoint(x: page.maxX, y: page.minY + r), control: CGPoint(x: page.maxX, y: page.minY))
    path.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
    path.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY))
    path.addLine(to: CGPoint(x: page.minX + r, y: page.maxY))
    path.addQuadCurve(to: CGPoint(x: page.minX, y: page.maxY - r), control: CGPoint(x: page.minX, y: page.maxY))
    path.addLine(to: CGPoint(x: page.minX, y: page.minY + r))
    path.addQuadCurve(to: CGPoint(x: page.minX + r, y: page.minY), control: CGPoint(x: page.minX, y: page.minY))
    path.closeSubpath()
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -6 * k), blur: 18 * k, color: CGColor(gray: 0, alpha: 0.30))
    c.addPath(path); c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fillPath()
    c.restoreGState()
    c.addPath(path); c.setStrokeColor(CGColor(gray: 0, alpha: 0.12)); c.setLineWidth(max(1, 3 * k)); c.strokePath()
    // the folded corner
    let corner = CGMutablePath()
    corner.move(to: CGPoint(x: page.maxX - fold, y: page.maxY))
    corner.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY - fold + 24 * k))
    corner.addQuadCurve(to: CGPoint(x: page.maxX - fold + 24 * k, y: page.maxY - fold), control: CGPoint(x: page.maxX - fold, y: page.maxY - fold))
    corner.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
    corner.closeSubpath()
    c.addPath(corner); c.setFillColor(CGColor(gray: 0.86, alpha: 1)); c.fillPath()
    c.addPath(corner); c.setStrokeColor(CGColor(gray: 0, alpha: 0.12)); c.setLineWidth(max(1, 3 * k)); c.strokePath()
    // Reel's icon in the middle
    let iconSize = 500 * k
    let iconRect = CGRect(x: 512 * k - iconSize / 2, y: 430 * k - iconSize / 2 + 60 * k, width: iconSize, height: iconSize)
    var r1 = iconRect
    if let cg = appIcon.cgImage(forProposedRect: &r1, context: nil, hints: nil) {
        c.interpolationQuality = .high; c.draw(cg, in: iconRect)
    }
    // "REEL" label (dropped at tiny sizes, like the system does)
    if px >= 64 {
        let ns = NSGraphicsContext(cgContext: c, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let font = NSFont.systemFont(ofSize: 110 * k, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(srgbRed: 0.42, green: 0.27, blue: 0.75, alpha: 1),
                                                    .paragraphStyle: para, .kern: 6 * k]
        ("REEL" as NSString).draw(in: CGRect(x: page.minX, y: page.minY + 70 * k, width: page.width, height: 140 * k), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }
    return c.makeImage()!
}

let iconset = root.appendingPathComponent(".build/ReelPlaylist.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (px, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"), (256, "128x128@2x"),
                   (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    try! NSBitmapImageRep(cgImage: render(px)).representation(using: .png, properties: [:])!
        .write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
try! NSBitmapImageRep(cgImage: render(1024)).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("Design/ReelPlaylist-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Design/ReelPlaylist.icns").path]
try! p.run(); p.waitUntilExit()
print("wrote Design/ReelPlaylist.icns")
