// Builds AppIcon.icns from Design/icon-creature-source.jpg.
//   swiftc -O scripts/make-icon.swift -o .build/make-icon && .build/make-icon
// The creature is cut out of its flat gray background (flood fill from the edges, so the gray inside
// the ears — fenced in by the dark outline — stays), then placed peeking up in front of a big play
// button, with a film edge down the left.
import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let srcURL = root.appendingPathComponent("Design/icon-creature-source.jpg")
let outPNG = root.appendingPathComponent("Design/AppIcon-1024.png")

// MARK: Cut-out

guard let src = NSBitmapImageRep(data: try! Data(contentsOf: srcURL)), let srcCG = src.cgImage else { fatalError("no source") }
let W = srcCG.width, H = srcCG.height
var px = [UInt8](repeating: 0, count: W * H * 4)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx0 = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx0.draw(srcCG, in: CGRect(x: 0, y: 0, width: W, height: H))
// note: CGContext rows run bottom-up in memory order relative to the image; we just treat it as a grid.

let bg = (r: Int(px[0]), g: Int(px[1]), b: Int(px[2]))
func isBG(_ i: Int) -> Bool {
    let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2])
    return abs(r - bg.r) <= 7 && abs(g - bg.g) <= 7 && abs(b - bg.b) <= 7 && abs(r - g) <= 5 && abs(g - b) <= 5
}
var mask = [UInt8](repeating: 0, count: W * H)          // 1 = background
var stack: [Int] = []
for x in 0..<W { stack.append(x); stack.append((H - 1) * W + x) }
for y in 0..<H { stack.append(y * W); stack.append(y * W + W - 1) }
while let i = stack.popLast() {
    if mask[i] == 1 || !isBG(i) { continue }
    mask[i] = 1
    let x = i % W, y = i / W
    if x > 0 { stack.append(i - 1) }; if x < W - 1 { stack.append(i + 1) }
    if y > 0 { stack.append(i - W) }; if y < H - 1 { stack.append(i + W) }
}
// grow the background by 1 px (eats JPEG fringe), then soften the edge for anti-aliasing
var grown = mask
for y in 1..<(H - 1) { for x in 1..<(W - 1) {
    let i = y * W + x
    if mask[i] == 0 && (mask[i - 1] == 1 || mask[i + 1] == 1 || mask[i - W] == 1 || mask[i + W] == 1) { grown[i] = 1 }
} }
var alpha = [Float](repeating: 0, count: W * H)
for y in 0..<H { for x in 0..<W {
    var sum: Float = 0, n: Float = 0
    for dy in -1...1 { for dx in -1...1 {
        let xx = min(max(x + dx, 0), W - 1), yy = min(max(y + dy, 0), H - 1)
        sum += grown[yy * W + xx] == 1 ? 0 : 1; n += 1
    } }
    alpha[y * W + x] = sum / n
} }
var cut = [UInt8](repeating: 0, count: W * H * 4)
var minX = W, maxX = 0, minY = H, maxY = 0
for i in 0..<(W * H) {
    let a = alpha[i]
    cut[i * 4] = UInt8(Float(px[i * 4]) * a); cut[i * 4 + 1] = UInt8(Float(px[i * 4 + 1]) * a)
    cut[i * 4 + 2] = UInt8(Float(px[i * 4 + 2]) * a); cut[i * 4 + 3] = UInt8(255 * a)
    if a > 0.5 { let x = i % W, y = i / W; minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
}
let cutCtx = CGContext(data: &cut, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let creatureFull = cutCtx.makeImage()!
// CG memory row 0 is the *top* of the image here, so the bbox y is top-down.
let creature = creatureFull.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!
print("creature bbox:", minX, minY, maxX, maxY)

// MARK: Compose (1024 × 1024, macOS icon grid: 824 body at 100 px inset)

let S = 1024
let canvas = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func top(_ y: CGFloat, _ h: CGFloat) -> CGFloat { CGFloat(S) - y - h }      // top-left coords → CG
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// soft shadow under the whole icon
canvas.saveGState()
canvas.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: rgb(0x000000, 0.35))
canvas.addPath(bodyPath); canvas.setFillColor(rgb(0x241c5c)); canvas.fillPath()
canvas.restoreGState()

canvas.saveGState()
canvas.addPath(bodyPath); canvas.clip()
// background: indigo → violet (the flower crown's colours), with a teal glow from the eyes' colour
// (start = bottom edge): light violet behind the creature, deep indigo up top
let grad = CGGradient(colorsSpace: cs, colors: [rgb(0x9277ea), rgb(0x5140b4), rgb(0x221c58)] as CFArray, locations: [0, 0.5, 1])!
canvas.drawLinearGradient(grad, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
let glow = CGGradient(colorsSpace: cs, colors: [rgb(0x37d6c8, 0.30), rgb(0x37d6c8, 0)] as CFArray, locations: [0, 1])!
canvas.drawRadialGradient(glow, startCenter: CGPoint(x: 580, y: top(352, 0)), startRadius: 0,
                          endCenter: CGPoint(x: 580, y: top(352, 0)), endRadius: 420, options: [])
// soft lavender light behind the creature's head so its dark outline reads against the background
let halo = CGGradient(colorsSpace: cs, colors: [rgb(0xc8b8ff, 0.55), rgb(0xa48bff, 0.22), rgb(0xa48bff, 0)] as CFArray, locations: [0, 0.45, 1])!
canvas.drawRadialGradient(halo, startCenter: CGPoint(x: 580, y: top(800, 0)), startRadius: 0,
                          endCenter: CGPoint(x: 580, y: top(800, 0)), endRadius: 420, options: [])

// film edge down the left: a dark strip with rounded square sprocket holes
let strip = CGRect(x: 100, y: 100, width: 108, height: 824)
canvas.setFillColor(rgb(0x0f0c26, 0.62)); canvas.fill(strip)
canvas.setFillColor(rgb(0xffffff, 0.10)); canvas.fill(CGRect(x: strip.maxX - 3, y: 100, width: 3, height: 824))   // strip edge
let hole: CGFloat = 46, pitch: CGFloat = 82
var hy: CGFloat = 100 + (824 - (floor(824 / pitch) * pitch - (pitch - hole))) / 2
while hy + hole <= 924 {
    canvas.addPath(CGPath(roundedRect: CGRect(x: strip.midX - hole / 2 - 4, y: hy, width: hole, height: hole), cornerWidth: 11, cornerHeight: 11, transform: nil))
    canvas.setFillColor(rgb(0xe9e1ff, 0.82)); canvas.fillPath()
    hy += pitch
}

// big play button behind the creature
let pc = CGPoint(x: 580, y: top(352, 0))
let pr: CGFloat = 228
canvas.saveGState()
canvas.setShadow(offset: CGSize(width: 0, height: -8), blur: 30, color: rgb(0x150f40, 0.45))
canvas.setFillColor(rgb(0xffffff, 0.16)); canvas.fillEllipse(in: CGRect(x: pc.x - pr, y: pc.y - pr, width: pr * 2, height: pr * 2))
canvas.restoreGState()
canvas.setStrokeColor(rgb(0xffffff, 0.30)); canvas.setLineWidth(4)
canvas.strokeEllipse(in: CGRect(x: pc.x - pr + 2, y: pc.y - pr + 2, width: pr * 2 - 4, height: pr * 2 - 4))
// rounded triangle: fill + a thick round-joined stroke of the same colour softens the corners
let tri = CGMutablePath()
let th: CGFloat = 112   // half height
tri.move(to: CGPoint(x: pc.x - 62, y: pc.y + th)); tri.addLine(to: CGPoint(x: pc.x - 62, y: pc.y - th))
tri.addLine(to: CGPoint(x: pc.x + 118, y: pc.y)); tri.closeSubpath()
canvas.saveGState()
canvas.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: rgb(0x1b1250, 0.40))
canvas.beginTransparencyLayer(auxiliaryInfo: nil)          // one shadow for fill + stroke together
canvas.setFillColor(rgb(0xffffff)); canvas.addPath(tri); canvas.fillPath()
canvas.setStrokeColor(rgb(0xffffff)); canvas.setLineWidth(30); canvas.setLineJoin(.round); canvas.addPath(tri); canvas.strokePath()
canvas.endTransparencyLayer()
canvas.restoreGState()

// the creature, peeking up from the bottom edge in front of the play button
let cw = CGFloat(creature.width), ch = CGFloat(creature.height)
let scale: CGFloat = 760 / cw
let dw = cw * scale, dh = ch * scale
let dest = CGRect(x: 580 - dw / 2, y: 100, width: dw, height: dh)     // its cut-off bottom sits on the icon's bottom edge
canvas.saveGState()
canvas.setShadow(offset: CGSize(width: 0, height: 8), blur: 26, color: rgb(0x000000, 0.55))
canvas.interpolationQuality = .high
canvas.draw(creature, in: dest)
canvas.restoreGState()

// glassy top sheen
let sheen = CGGradient(colorsSpace: cs, colors: [rgb(0xffffff, 0.16), rgb(0xffffff, 0)] as CFArray, locations: [0, 1])!
canvas.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
canvas.restoreGState()

// thin edge highlight
canvas.addPath(CGPath(roundedRect: body.insetBy(dx: 1, dy: 1), cornerWidth: 184, cornerHeight: 184, transform: nil))
canvas.setStrokeColor(rgb(0xffffff, 0.18)); canvas.setLineWidth(2); canvas.strokePath()

let icon = canvas.makeImage()!
let rep = NSBitmapImageRep(cgImage: icon)
try! rep.representation(using: .png, properties: [:])!.write(to: outPNG)
print("wrote", outPNG.path)

// MARK: iconset → AppIcon.icns

let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (px, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"), (256, "128x128@2x"),
                   (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.draw(icon, in: CGRect(x: 0, y: 0, width: px, height: px))
    try! NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!
        .write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Design/AppIcon-new.icns").path]
try! p.run(); p.waitUntilExit()
print("wrote Design/AppIcon-new.icns")
