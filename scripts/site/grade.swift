// Relights a cut-out (transparent PNG) so its lightest material reaches a target colour — e.g. the creature's
// chest fur, which is a cool white but photographs mid-grey under dim, warm light.
//   swiftc -O scripts/site/grade.swift -o .build/grade
//   .build/grade <in.png> <out.png> [r,g,b target for the lightest 6%, default 236,242,251]
// Works in linear light, per channel (so a warm cast becomes cool), like adding a key light: the light material
// gets the full lift, dark fur only a little (so it stays dark and the design keeps its contrast), with a soft
// shoulder so the brightest fur doesn't clip. Transparency is left as it is.
import AppKit

let a = CommandLine.arguments
guard a.count >= 3 else { print("usage: grade <in.png> <out.png> [r,g,b]"); exit(2) }
let target = (a.count > 3 ? a[3] : "236,242,251").split(separator: ",").compactMap { Double($0) }.map { $0 / 255 }
guard target.count == 3, let rep = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: a[1]))), let cg = rep.cgImage else { print("bad input"); exit(1) }

let W = cg.width, H = cg.height
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
var px = [UInt8](repeating: 0, count: W * H * 4)
let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))

func toLinear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
func toSRGB(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }

// un-premultiplied colour of opaque pixels, sorted by brightness → the lightest 6%
var light: [(Double, Double, Double, Double)] = []
for i in 0..<(W * H) where px[i * 4 + 3] > 245 {
    let r = Double(px[i * 4]) / 255, g = Double(px[i * 4 + 1]) / 255, b = Double(px[i * 4 + 2]) / 255
    light.append((r, g, b, 0.2126 * r + 0.7152 * g + 0.0722 * b))
}
light.sort { $0.3 > $1.3 }
let top = light.prefix(max(1, light.count * 6 / 100))
let m = top.reduce((0.0, 0.0, 0.0)) { ($0.0 + toLinear($1.0), $0.1 + toLinear($1.1), $0.2 + toLinear($1.2)) }
let n = Double(top.count)
let gain = [toLinear(target[0]) / (m.0 / n), toLinear(target[1]) / (m.1 / n), toLinear(target[2]) / (m.2 / n)]

// soft shoulder: linear up to 0.8, then eases toward 1 instead of clipping
func shoulder(_ x: Double) -> Double { x <= 0.8 ? x : 0.8 + 0.2 * (1 - exp(-(x - 0.8) / 0.2)) }

func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double { let t = max(0, min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t) }
for i in 0..<(W * H) {
    let al = Double(px[i * 4 + 3]) / 255
    guard al > 0 else { continue }
    let lin = (0..<3).map { toLinear(Double(px[i * 4 + $0]) / 255 / al) }        // un-premultiplied, linear
    let lum = 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]
    let w = 0.3 + 0.7 * smoothstep(0.03, 0.22, lum)                               // darks get 30% of the lift
    for c in 0..<3 {
        let out = toSRGB(shoulder(lin[c] * (1 + (gain[c] - 1) * w)))
        px[i * 4 + c] = UInt8(max(0, min(255, (out * al * 255).rounded())))
    }
}
let outCG = ctx.makeImage()!
try NSBitmapImageRep(cgImage: outCG).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
print(String(format: "lightest 6%% was rgb(%.0f, %.0f, %.0f); linear gains r %.2f g %.2f b %.2f → %@",
             toSRGB(m.0 / n) * 255, toSRGB(m.1 / n) * 255, toSRGB(m.2 / n) * 255, gain[0], gain[1], gain[2], a[2]))
