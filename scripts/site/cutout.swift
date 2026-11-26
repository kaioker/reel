// Cuts the creature out of a photo with a flat background (the same way scripts/make-icon.swift does):
// flood fill from the top, left and right edges — never the bottom, where the creature runs off the frame —
// then a soft 1 px edge. Writes a transparent PNG cropped to the creature, at most `max` pixels tall.
//   swiftc -O scripts/site/cutout.swift -o .build/cutout && .build/cutout <in.png> <out.png> [max-height]
import AppKit

let a = CommandLine.arguments
guard a.count >= 3 else { print("usage: cutout <in> <out> [max-height]"); exit(2) }
let maxH = a.count > 3 ? Int(a[3]) ?? 1200 : 1200
guard let rep = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: a[1]))), let srcCG = rep.cgImage else { print("can't read"); exit(1) }
let W = srcCG.width, H = srcCG.height
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
var px = [UInt8](repeating: 0, count: W * H * 4)
let c0 = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs,
                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
c0.draw(srcCG, in: CGRect(x: 0, y: 0, width: W, height: H))

// background colour: the average of the top row (it's flat)
var sr = 0, sg = 0, sb = 0
for x in 0..<W { sr += Int(px[x * 4]); sg += Int(px[x * 4 + 1]); sb += Int(px[x * 4 + 2]) }
let bg = (r: sr / W, g: sg / W, b: sb / W)
func isBG(_ i: Int) -> Bool {
    let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2])
    return abs(r - bg.r) <= 6 && abs(g - bg.g) <= 6 && abs(b - bg.b) <= 6 && abs(r - g) <= 5 && abs(g - b) <= 5
}
var mask = [UInt8](repeating: 0, count: W * H)          // 1 = background
var stack: [Int] = []
for x in 0..<W { stack.append(x) }                        // top row (memory row 0 is the top here)
for y in 0..<H { stack.append(y * W); stack.append(y * W + W - 1) }
while let i = stack.popLast() {
    if mask[i] == 1 || !isBG(i) { continue }
    mask[i] = 1
    let x = i % W, y = i / W
    if x > 0 { stack.append(i - 1) }; if x < W - 1 { stack.append(i + 1) }
    if y > 0 { stack.append(i - W) }; if y < H - 1 { stack.append(i + W) }
}
var grown = mask                                           // eat a 1 px fringe of compression noise
for y in 1..<(H - 1) { for x in 1..<(W - 1) {
    let i = y * W + x
    if mask[i] == 0 && (mask[i - 1] == 1 || mask[i + 1] == 1 || mask[i - W] == 1 || mask[i + W] == 1) { grown[i] = 1 }
} }
var out = [UInt8](repeating: 0, count: W * H * 4)
var minX = W, maxX = 0, minY = H, maxY = 0
for y in 0..<H { for x in 0..<W {
    var sum: Float = 0
    for dy in -1...1 { for dx in -1...1 {
        let xx = min(max(x + dx, 0), W - 1), yy = min(max(y + dy, 0), H - 1)
        sum += grown[yy * W + xx] == 1 ? 0 : 1
    } }
    let al = sum / 9, i = y * W + x
    for k in 0..<3 { out[i * 4 + k] = UInt8(Float(px[i * 4 + k]) * al) }
    out[i * 4 + 3] = UInt8(255 * al)
    if al > 0.5 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
} }
let ctx = CGContext(data: &out, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let crop = ctx.makeImage()!.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!
let scale = min(1, Double(maxH) / Double(crop.height))
let ow = Int(Double(crop.width) * scale), oh = Int(Double(crop.height) * scale)
let sc = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
sc.interpolationQuality = .high
sc.draw(crop, in: CGRect(x: 0, y: 0, width: ow, height: oh))
try NSBitmapImageRep(cgImage: sc.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
print("background \(bg) → \(ow)x\(oh) \(a[2])")
