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
    return abs(r - bg.r) <= 5 && abs(g - bg.g) <= 5 && abs(b - bg.b) <= 5 && abs(r - g) <= 4 && abs(g - b) <= 4
}
var mask = [UInt8](repeating: 0, count: W * H)          // 1 = background
var stack: [Int] = []
// seed from the top, left and right edges only — the bottom edge is where the creature is cropped,
// and its cheek fur there is nearly the background's gray, so seeding there ate into the cheeks
for x in 0..<W { stack.append(x) }
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
if let dbg = ProcessInfo.processInfo.environment["ICON_DEBUG_CUTOUT"] {      // the cut-out over bright green
    let c = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0.2, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: W, height: H))
    c.draw(creatureFull, in: CGRect(x: 0, y: 0, width: W, height: H))
    try! NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dbg))
}

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
let grad = CGGradient(colorsSpace: cs, colors: [rgb(0xb8329c), rgb(0x9a35b4), rgb(0x6a3cc6), rgb(0x2a1466)] as CFArray, locations: [0, 0.3, 0.6, 1])!   // lower half: rich pink · top: deep violet
canvas.drawLinearGradient(grad, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
let glow = CGGradient(colorsSpace: cs, colors: [rgb(0x37d6c8, 0.30), rgb(0x37d6c8, 0)] as CFArray, locations: [0, 1])!
canvas.drawRadialGradient(glow, startCenter: CGPoint(x: 573, y: 512), startRadius: 0,
                          endCenter: CGPoint(x: 573, y: 512), endRadius: 420, options: [])
// soft lavender light behind the creature's head so its dark outline reads against the background
let halo = CGGradient(colorsSpace: cs, colors: [rgb(0xf0a6ea, 0.42), rgb(0xd47ad8, 0.18), rgb(0xd47ad8, 0)] as CFArray, locations: [0, 0.45, 1])!
canvas.drawRadialGradient(halo, startCenter: CGPoint(x: 573, y: top(800, 0)), startRadius: 0,
                          endCenter: CGPoint(x: 573, y: top(800, 0)), endRadius: 420, options: [])

// film edge down the left: a dark strip with rounded square sprocket holes
let strip = CGRect(x: 100, y: 100, width: 124, height: 824)
// glass strip: deeper at the outer edge, lifting toward the picture, with a soft vertical sheen
canvas.saveGState()
canvas.clip(to: strip)
let stripG = CGGradient(colorsSpace: cs, colors: [rgb(0x0b0820, 0.74), rgb(0x150f36, 0.58), rgb(0x241a52, 0.46)] as CFArray, locations: [0, 0.6, 1])!
canvas.drawLinearGradient(stripG, start: CGPoint(x: strip.minX, y: 512), end: CGPoint(x: strip.maxX, y: 512), options: [])
let stripSheen = CGGradient(colorsSpace: cs, colors: [rgb(0xffffff, 0.10), rgb(0xffffff, 0.0), rgb(0xffffff, 0.04)] as CFArray, locations: [0, 0.5, 1])!
canvas.drawLinearGradient(stripSheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
canvas.restoreGState()
// where the strip meets the picture: a bright glass line over a thin dark groove
canvas.setFillColor(rgb(0x000000, 0.22)); canvas.fill(CGRect(x: strip.maxX, y: 100, width: 3, height: 824))
let seam = CGGradient(colorsSpace: cs, colors: [rgb(0xffffff, 0.36), rgb(0xffffff, 0.14), rgb(0xffffff, 0.06)] as CFArray, locations: [0, 0.5, 1])!
canvas.saveGState(); canvas.clip(to: CGRect(x: strip.maxX - 3, y: 100, width: 3, height: 824))
canvas.drawLinearGradient(seam, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: []); canvas.restoreGState()
// sprocket holes — punched right through the icon at the very end, so they're truly transparent
let hole: CGFloat = 60, pitch: CGFloat = 100
// full height, evenly spaced and symmetric about the middle; the ones at the very top and bottom
// run off the rounded corners like film leaving the frame
var holes: [CGRect] = []
let count = Int(ceil(824 / pitch)) + 1
let first = 512 - (CGFloat(count - 1) * pitch + hole) / 2
for k in 0..<count {
    holes.append(CGRect(x: strip.midX - hole / 2 - 4, y: first + CGFloat(k) * pitch, width: hole, height: hole))
}
// the picture area is everything right of the film edge; centre things in that
let frameMidX = (strip.maxX + 924) / 2

// big play button behind the creature
// centred in the picture area, then nudged left by a third of the gap between the disc and the film edge
let discGap = (frameMidX - 228) - strip.maxX
let pc = CGPoint(x: frameMidX - discGap / 3, y: 512)
// Liquid Glass disc behind it: frosted body, curved top highlight, light-catching rim, refraction glow
let pr: CGFloat = 228
let discRect = CGRect(x: pc.x - pr, y: pc.y - pr, width: pr * 2, height: pr * 2)
let disc = CGPath(ellipseIn: discRect, transform: nil)
// soft shadow under the glass
canvas.saveGState()
canvas.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: rgb(0x120a38, 0.30))
canvas.addPath(disc); canvas.setFillColor(rgb(0xffffff, 0.04)); canvas.fillPath()
canvas.restoreGState()
canvas.saveGState()
canvas.addPath(disc); canvas.clip()
// frosted body: a touch of blur + brightening of whatever's behind, lighter toward the top
let body2 = CGGradient(colorsSpace: cs, colors: [rgb(0xffffff, 0.10), rgb(0xffffff, 0.045), rgb(0xffffff, 0.03)] as CFArray, locations: [0, 0.55, 1])!
canvas.drawLinearGradient(body2, start: CGPoint(x: pc.x, y: discRect.maxY), end: CGPoint(x: pc.x, y: discRect.minY), options: [])
// curved specular highlight across the top
let spec = CGPath(ellipseIn: CGRect(x: pc.x - pr * 0.78, y: pc.y + pr * 0.28, width: pr * 1.56, height: pr * 0.86), transform: nil)
canvas.saveGState()
canvas.addPath(spec); canvas.clip()
let specG = CGGradient(colorsSpace: cs, colors: [rgb(0xffffff, 0.14), rgb(0xffffff, 0.0)] as CFArray, locations: [0, 1])!
canvas.drawLinearGradient(specG, start: CGPoint(x: pc.x, y: discRect.maxY), end: CGPoint(x: pc.x, y: pc.y + pr * 0.32), options: [])
canvas.restoreGState()
// refraction: light pooling along the bottom inside edge
let refr = CGGradient(colorsSpace: cs, colors: [rgb(0xf3d9ff, 0.0), rgb(0xf3d9ff, 0.09)] as CFArray, locations: [0, 1])!
canvas.drawRadialGradient(refr, startCenter: CGPoint(x: pc.x, y: pc.y + pr * 0.12), startRadius: pr * 0.70,
                          endCenter: pc, endRadius: pr, options: [])
canvas.restoreGState()
// rim: bright where light hits (top-left), fading round to the bottom-right
canvas.saveGState()
canvas.addPath(CGPath(ellipseIn: discRect.insetBy(dx: 1.5, dy: 1.5), transform: nil))
canvas.setLineWidth(3); canvas.replacePathWithStrokedPath(); canvas.clip()
let rim = CGGradient(colorsSpace: cs, colors: [rgb(0xffffff, 0.38), rgb(0xffffff, 0.12), rgb(0xffffff, 0.20)] as CFArray, locations: [0, 0.6, 1])!
canvas.drawLinearGradient(rim, start: CGPoint(x: discRect.minX + pr * 0.3, y: discRect.maxY - pr * 0.3),
                          end: CGPoint(x: discRect.maxX - pr * 0.3, y: discRect.minY + pr * 0.3), options: [])
canvas.restoreGState()
// rounded triangle: fill + a thick round-joined stroke of the same colour softens the corners
let tri = CGMutablePath()
let th: CGFloat = 112   // half height
tri.move(to: CGPoint(x: pc.x - 62, y: pc.y + th)); tri.addLine(to: CGPoint(x: pc.x - 62, y: pc.y - th))
tri.addLine(to: CGPoint(x: pc.x + 118, y: pc.y)); tri.closeSubpath()
canvas.saveGState()
canvas.setShadow(offset: CGSize(width: 0, height: -8), blur: 26, color: rgb(0x1b1250, 0.50))
canvas.beginTransparencyLayer(auxiliaryInfo: nil)          // one shadow for fill + stroke together
canvas.setFillColor(rgb(0xffffff)); canvas.addPath(tri); canvas.fillPath()
canvas.setStrokeColor(rgb(0xffffff)); canvas.setLineWidth(30); canvas.setLineJoin(.round); canvas.addPath(tri); canvas.strokePath()
canvas.endTransparencyLayer()
canvas.restoreGState()

// --- glass over the whole icon — drawn *before* the creature, so it never covers it ---
// curved highlight across the top, like light on a sheet of glass
canvas.saveGState()
canvas.addPath(CGPath(ellipseIn: CGRect(x: 30, y: 600, width: 964, height: 520), transform: nil)); canvas.clip()
let topSheen = CGGradient(colorsSpace: cs, colors: [rgb(0xffffff, 0.17), rgb(0xffffff, 0.04), rgb(0xffffff, 0)] as CFArray, locations: [0, 0.5, 1])!
canvas.drawLinearGradient(topSheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
canvas.restoreGState()
// light pooling along the bottom inside edge (refraction), in the gradient's pink
let pool = CGGradient(colorsSpace: cs, colors: [rgb(0xff8fd8, 0.20), rgb(0xff8fd8, 0)] as CFArray, locations: [0, 1])!
canvas.drawLinearGradient(pool, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 230), options: [])
// glass edge: a soft inner band plus a crisp line, bright along the top, fading down the sides, gone at the bottom
func edge(inset: CGFloat, width: CGFloat, alphas: [CGFloat]) {
    canvas.saveGState()
    canvas.addPath(CGPath(roundedRect: body.insetBy(dx: inset, dy: inset), cornerWidth: 185 - inset, cornerHeight: 185 - inset, transform: nil))
    canvas.setLineWidth(width); canvas.replacePathWithStrokedPath(); canvas.clip()
    let g = CGGradient(colorsSpace: cs, colors: alphas.map { rgb(0xffffff, $0) } as CFArray, locations: [0, 0.45, 1])!
    canvas.drawLinearGradient(g, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    canvas.restoreGState()
}
edge(inset: 7, width: 12, alphas: [0.12, 0.04, 0.0])
edge(inset: 1.5, width: 2.5, alphas: [0.46, 0.14, 0.0])

// the creature, peeking up from the bottom edge in front of the play button
let cw = CGFloat(creature.width), ch = CGFloat(creature.height)
let scale: CGFloat = 760 / cw
let dw = cw * scale, dh = ch * scale
let dest = CGRect(x: frameMidX - dw / 2, y: 100, width: dw, height: dh)     // its cut-off bottom sits on the icon's bottom edge
canvas.saveGState()
canvas.setShadow(offset: CGSize(width: 0, height: 8), blur: 26, color: rgb(0x000000, 0.55))
canvas.interpolationQuality = .high
canvas.draw(creature, in: dest)
canvas.restoreGState()
canvas.restoreGState()   // end of the icon-shape clip

// punch the sprocket holes (transparent all the way through)
canvas.saveGState()
canvas.setBlendMode(.clear)
for h in holes { canvas.addPath(CGPath(roundedRect: h, cornerWidth: 14, cornerHeight: 14, transform: nil)) }
canvas.fillPath()
canvas.restoreGState()
// each hole looks cut through thick glass: a soft shadow inside the lower-right edge of the cut,
// and a bright rim where light catches the top-left
canvas.saveGState()
canvas.addPath(bodyPath); canvas.clip()            // only where there's icon
for h in holes {
    let ring = CGPath(roundedRect: h.insetBy(dx: -1.5, dy: -1.5), cornerWidth: 15.5, cornerHeight: 15.5, transform: nil)
    // shadow band just outside the hole's lower-right (depth)
    canvas.saveGState()
    canvas.addPath(CGPath(roundedRect: h.insetBy(dx: -7, dy: -7), cornerWidth: 20, cornerHeight: 20, transform: nil))
    canvas.addPath(ring); canvas.clip(using: .evenOdd)
    let depth = CGGradient(colorsSpace: cs, colors: [rgb(0x000000, 0.0), rgb(0x000000, 0.0), rgb(0x05030f, 0.40)] as CFArray, locations: [0, 0.45, 1])!
    canvas.drawLinearGradient(depth, start: CGPoint(x: h.minX - 7, y: h.maxY + 7), end: CGPoint(x: h.maxX + 7, y: h.minY - 7), options: [])
    canvas.restoreGState()
    // light-catching rim
    canvas.saveGState()
    canvas.addPath(ring); canvas.setLineWidth(3); canvas.replacePathWithStrokedPath(); canvas.clip()
    let rimG = CGGradient(colorsSpace: cs, colors: [rgb(0xffffff, 0.62), rgb(0xffffff, 0.16), rgb(0xffffff, 0.05)] as CFArray, locations: [0, 0.5, 1])!
    canvas.drawLinearGradient(rimG, start: CGPoint(x: h.minX, y: h.maxY), end: CGPoint(x: h.maxX, y: h.minY), options: [])
    canvas.restoreGState()
}
canvas.restoreGState()

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
