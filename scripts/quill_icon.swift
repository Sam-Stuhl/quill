// quill_icon.swift: draws Quill's iOS app icons (a flat quill glyph: a solid feather with
// its shaft cut out, writing a small s and a line) into
// ios/Runner/Assets.xcassets/AppIcon.appiconset, every size its Contents.json lists, in
// the three variants iOS asks for (light, dark, tinted).
//   swift scripts/quill_icon.swift
// Quill's own icons stay under assets/icon (upstream merges untouched); only the iOS
// asset catalog is replaced.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let dir = "ios/Runner/Assets.xcassets/AppIcon.appiconset"

struct Look { let bg: CGColor, ink: CGColor }
func rgb(_ r: Double, _ g: Double, _ b: Double) -> CGColor { CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1) }
let looks: [String: Look] = [
    "Icon-App": Look(bg: rgb(248, 245, 238), ink: rgb(22, 24, 32)),
    "Icon-App-Dark": Look(bg: rgb(18, 19, 24), ink: rgb(244, 240, 230)),
    "Icon-App-Tinted": Look(bg: rgb(0, 0, 0), ink: rgb(236, 236, 236)),
]

// The feather's shaft as a cubic on a 1000 grid, origin bottom left: base at the lower left, tip at the upper right.
let p0 = CGPoint(x: 470, y: 400), p1 = CGPoint(x: 520, y: 600), p2 = CGPoint(x: 640, y: 770), p3 = CGPoint(x: 790, y: 860)
func bez(_ t: CGFloat) -> CGPoint {
    let u = 1 - t
    return CGPoint(x: u*u*u*p0.x + 3*u*u*t*p1.x + 3*u*t*t*p2.x + t*t*t*p3.x,
                   y: u*u*u*p0.y + 3*u*u*t*p1.y + 3*u*t*t*p2.y + t*t*t*p3.y)
}
func normal(_ t: CGFloat) -> CGPoint {
    let a = bez(max(0, t - 0.001)), b = bez(min(1, t + 0.001))
    let dx = b.x - a.x, dy = b.y - a.y, l = (dx*dx + dy*dy).squareRoot()
    return CGPoint(x: -dy / l, y: dx / l)
}
// Half width of the vane at t on one side, with one notch cut into the right side.
func width(_ t: CGFloat, max w: CGFloat, notch: CGFloat?) -> CGFloat {
    var v = w * pow(sin(.pi * pow(t, 0.7)), 0.85)
    if let c = notch {
        let d = t - c
        if d > -0.09 && d < 0.0 { v *= 0.45 + 0.55 * (-d / 0.09) }
    }
    return v
}
func vane() -> CGPath {
    var left: [CGPoint] = [], right: [CGPoint] = []
    for i in 0...300 {
        let t = CGFloat(i) / 300
        let c = bez(t), n = normal(t)
        let wl = width(t, max: 120, notch: nil), wr = width(t, max: 130, notch: 0.5)
        left.append(CGPoint(x: c.x + n.x * wl, y: c.y + n.y * wl))
        right.append(CGPoint(x: c.x - n.x * wr, y: c.y - n.y * wr))
    }
    let p = CGMutablePath()
    p.addLines(between: left)
    for q in right.reversed() { p.addLine(to: q) }
    p.closeSubpath()
    return p
}

func draw(_ look: Look, size px: Int) -> CGImage {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(look.bg)
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
    ctx.scaleBy(x: s / 1000, y: s / 1000)
    ctx.translateBy(x: 0, y: 10)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    // The solid feather.
    ctx.setFillColor(look.ink)
    ctx.addPath(vane())
    ctx.fillPath()
    // The shaft, cut out of the feather in the background colour.
    ctx.setStrokeColor(look.bg)
    ctx.setLineWidth(18)
    ctx.move(to: bez(0.0))
    for i in 1...40 { ctx.addLine(to: bez(0.76 * CGFloat(i) / 40)) }
    ctx.strokePath()
    // Below the feather, the quill's stem runs down into a small s and the line it wrote.
    ctx.setStrokeColor(look.ink)
    ctx.setLineWidth(30)
    ctx.move(to: bez(0.04))
    ctx.addLine(to: CGPoint(x: 452, y: 300))
    ctx.addCurve(to: CGPoint(x: 452, y: 225), control1: CGPoint(x: 400, y: 290), control2: CGPoint(x: 400, y: 245))
    ctx.addCurve(to: CGPoint(x: 445, y: 160), control1: CGPoint(x: 510, y: 205), control2: CGPoint(x: 500, y: 160))
    ctx.addLine(to: CGPoint(x: 270, y: 160))
    ctx.strokePath()
    return ctx.makeImage()!
}

func write(_ image: CGImage, to path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    precondition(CGImageDestinationFinalize(dest))
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
