// quill_icon.swift: draws Quill's iOS app icons (a feather quill writing a gold ink line
// on ink blue) into ios/Runner/Assets.xcassets/AppIcon.appiconset, every size its
// Contents.json lists, in the three variants iOS asks for (light, dark, tinted).
//   swift scripts/quill_icon.swift
// Saber's own icons stay under assets/icon (upstream merges untouched); only the iOS
// asset catalog is replaced.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let dir = "ios/Runner/Assets.xcassets/AppIcon.appiconset"

struct Look {
    let top: CGColor, bottom: CGColor, feather: CGColor, featherShade: CGColor, spine: CGColor, nib: CGColor, ink: CGColor
}
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}
let looks: [String: Look] = [
    "Icon-App": Look(top: rgb(46, 78, 156), bottom: rgb(16, 28, 70), feather: rgb(250, 245, 232),
                     featherShade: rgb(214, 202, 178), spine: rgb(170, 140, 96), nib: rgb(232, 186, 92),
                     ink: rgb(232, 186, 92)),
    "Icon-App-Dark": Look(top: rgb(26, 30, 46), bottom: rgb(8, 10, 18), feather: rgb(196, 214, 250),
                          featherShade: rgb(120, 146, 200), spine: rgb(80, 100, 150), nib: rgb(232, 186, 92),
                          ink: rgb(232, 186, 92)),
    "Icon-App-Tinted": Look(top: rgb(40, 40, 40), bottom: rgb(0, 0, 0), feather: rgb(240, 240, 240),
                            featherShade: rgb(170, 170, 170), spine: rgb(120, 120, 120), nib: rgb(210, 210, 210),
                            ink: rgb(210, 210, 210)),
]

// The rachis (the feather's central shaft) as a cubic, on a 1000 grid, origin bottom left.
let p0 = CGPoint(x: 300, y: 235), p1 = CGPoint(x: 390, y: 520), p2 = CGPoint(x: 560, y: 760), p3 = CGPoint(x: 835, y: 870)
func bez(_ t: CGFloat) -> CGPoint {
    let u = 1 - t
    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
    return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x, y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
}
func normal(_ t: CGFloat) -> CGPoint {
    let e: CGFloat = 0.001
    let a = bez(max(0, t - e)), b = bez(min(1, t + e))
    let dx = b.x - a.x, dy = b.y - a.y, l = (dx * dx + dy * dy).squareRoot()
    return CGPoint(x: -dy / l, y: dx / l)  // left of the direction of travel (up and to the left)
}
let vaneStart: CGFloat = 0.16
// Half width of the vane on one side at u (0 at the vane's base, 1 at the tip).
func width(_ u: CGFloat, max w: CGFloat, notches: [CGFloat]) -> CGFloat {
    var v = w * pow(sin(.pi * pow(u, 0.6)), 0.8) * pow(1 - u, 0.3)
    for c in notches {
        let d = u - c
        if d > -0.06 && d < 0.008 { v *= 0.66 + 0.34 * (d < 0 ? -d / 0.06 : d / 0.008) }
    }
    return max(v, 0)
}
func vanePath() -> CGPath {
    let p = CGMutablePath()
    let n = 240
    var left: [CGPoint] = [], right: [CGPoint] = []
    for i in 0...n {
        let u = CGFloat(i) / CGFloat(n)
        let t = vaneStart + (1 - vaneStart) * u
        let c = bez(t), nv = normal(t)
        // Barbs sweep toward the tip: offset each edge point forward along the shaft.
        let wl = width(u, max: 118, notches: [0.58])
        let wr = width(u, max: 150, notches: [0.34, 0.7])
        let fwdL = bez(min(1, t + 0.05 * wl / 118)), fwdR = bez(min(1, t + 0.06 * wr / 150))
        left.append(CGPoint(x: fwdL.x + nv.x * wl - (fwdL.x - c.x) * 0, y: fwdL.y + nv.y * wl))
        right.append(CGPoint(x: fwdR.x - nv.x * wr, y: fwdR.y - nv.y * wr))
    }
    p.move(to: bez(vaneStart))
    for q in left { p.addLine(to: q) }
    for q in right.reversed() { p.addLine(to: q) }
    p.closeSubpath()
    return p
}

func draw(_ look: Look, size px: Int) -> CGImage {
    let s = CGFloat(px)
    let space = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let bg = CGGradient(colorsSpace: space, colors: [look.top, look.bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: s), end: CGPoint(x: s * 0.3, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.scaleBy(x: s / 1000, y: s / 1000)

    // Ink swash under the nib: one cursive stroke, as if the quill just wrote it.
    ctx.setStrokeColor(look.ink)
    ctx.setLineCap(.round)
    ctx.setLineWidth(22)
    ctx.move(to: CGPoint(x: 150, y: 150))
    ctx.addCurve(to: CGPoint(x: 470, y: 150), control1: CGPoint(x: 240, y: 70), control2: CGPoint(x: 330, y: 240))
    ctx.addCurve(to: CGPoint(x: 820, y: 130), control1: CGPoint(x: 600, y: 60), control2: CGPoint(x: 700, y: 200))
    ctx.strokePath()

    // The vane, with a soft shade along the lower side.
    let vane = vanePath()
    ctx.saveGState()
    ctx.addPath(vane)
    ctx.clip()
    let shade = CGGradient(colorsSpace: space, colors: [look.feather, look.feather, look.featherShade] as CFArray,
                           locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(shade, start: CGPoint(x: 420, y: 760), end: CGPoint(x: 700, y: 420), options: [.drawsAfterEndLocation, .drawsBeforeStartLocation])
    // Barbs: fine lines from the shaft outward and forward.
    ctx.setStrokeColor(look.featherShade.copy(alpha: 0.55)!)
    ctx.setLineWidth(4)
    var t = vaneStart + 0.03
    while t < 0.97 {
        let c = bez(t), nv = normal(t)
        for side in [CGFloat(1), -1] {
            let f = bez(min(1, t + 0.07))
            ctx.move(to: c)
            ctx.addLine(to: CGPoint(x: f.x + nv.x * 170 * side, y: f.y + nv.y * 170 * side))
        }
        t += 0.045
    }
    ctx.strokePath()
    ctx.restoreGState()

    // The rachis: tapered, thick at the base and fine at the tip.
    ctx.setFillColor(look.spine)
    let shaft = CGMutablePath()
    var a: [CGPoint] = [], b: [CGPoint] = []
    let m = 120
    for i in 0...m {
        let t = CGFloat(i) / CGFloat(m) * 0.985
        let c = bez(t), nv = normal(t)
        let w = 11 * (1 - t) + 1.5
        a.append(CGPoint(x: c.x + nv.x * w, y: c.y + nv.y * w))
        b.append(CGPoint(x: c.x - nv.x * w, y: c.y - nv.y * w))
    }
    shaft.addLines(between: a)
    for q in b.reversed() { shaft.addLine(to: q) }
    shaft.closeSubpath()
    ctx.addPath(shaft)
    ctx.fillPath()

    // The nib, cut from the shaft's end, gold, with its slit.
    let dir = CGPoint(x: p0.x - p1.x, y: p0.y - p1.y)
    let dl = (dir.x * dir.x + dir.y * dir.y).squareRoot()
    let d = CGPoint(x: dir.x / dl, y: dir.y / dl), nn = CGPoint(x: -d.y, y: d.x)
    let tip = CGPoint(x: p0.x + d.x * 95, y: p0.y + d.y * 95)
    let nib = CGMutablePath()
    nib.move(to: CGPoint(x: p0.x + nn.x * 15, y: p0.y + nn.y * 15))
    nib.addQuadCurve(to: tip, control: CGPoint(x: p0.x + d.x * 55 + nn.x * 16, y: p0.y + d.y * 55 + nn.y * 16))
    nib.addQuadCurve(to: CGPoint(x: p0.x - nn.x * 15, y: p0.y - nn.y * 15),
                     control: CGPoint(x: p0.x + d.x * 55 - nn.x * 16, y: p0.y + d.y * 55 - nn.y * 16))
    nib.closeSubpath()
    ctx.setFillColor(look.nib)
    ctx.addPath(nib)
    ctx.fillPath()
    ctx.setStrokeColor(look.bottom)
    ctx.setLineWidth(4)
    ctx.move(to: CGPoint(x: p0.x + d.x * 30, y: p0.y + d.y * 30))
    ctx.addLine(to: CGPoint(x: p0.x + d.x * 82, y: p0.y + d.y * 82))
    ctx.strokePath()
    ctx.setFillColor(look.bottom)
    ctx.fillEllipse(in: CGRect(x: p0.x + d.x * 30 - 6, y: p0.y + d.y * 30 - 6, width: 12, height: 12))
    return ctx.makeImage()!
}

func write(_ image: CGImage, to path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    precondition(CGImageDestinationFinalize(dest), "could not write \(path)")
}
let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(dir)/Contents.json")))
var count = 0
for entry in (json as! [String: Any])["images"] as! [[String: Any]] {
    guard let file = entry["filename"] as? String else { continue }
    let base = file.components(separatedBy: "-").dropLast().joined(separator: "-")
    guard let look = looks[base] else { fatalError("no look for \(file)") }
    let points = Double((entry["size"] as! String).components(separatedBy: "x")[0])!
    let scale = Double((entry["scale"] as! String).dropLast())!
    write(draw(look, size: Int((points * scale).rounded())), to: "\(dir)/\(file)")
    count += 1
}
print("wrote \(count) icons")
