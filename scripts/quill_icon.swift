// quill_icon.swift: draws Quill's iOS app icons (a feather quill on ink blue) into
// ios/Runner/Assets.xcassets/AppIcon.appiconset, every size its Contents.json lists,
// in the three variants iOS asks for (light, dark, tinted).
//   swift scripts/quill_icon.swift
// Saber's own icons stay under assets/icon (upstream merges untouched); only the iOS
// asset catalog is replaced.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let dir = "ios/Runner/Assets.xcassets/AppIcon.appiconset"

struct Look {
    let top: CGColor, bottom: CGColor, feather: CGColor, spine: CGColor, ink: CGColor
}
func rgb(_ r: Double, _ g: Double, _ b: Double) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}
let looks: [String: Look] = [
    "Icon-App": Look(top: rgb(52, 84, 160), bottom: rgb(22, 36, 80), feather: rgb(247, 241, 226),
                     spine: rgb(34, 54, 112), ink: rgb(247, 241, 226)),
    "Icon-App-Dark": Look(top: rgb(24, 28, 42), bottom: rgb(8, 10, 18), feather: rgb(150, 182, 240),
                          spine: rgb(18, 24, 44), ink: rgb(150, 182, 240)),
    "Icon-App-Tinted": Look(top: rgb(40, 40, 40), bottom: rgb(0, 0, 0), feather: rgb(235, 235, 235),
                            spine: rgb(20, 20, 20), ink: rgb(235, 235, 235)),
]

func draw(_ look: Look, size px: Int) -> CGImage {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [look.top, look.bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    // Unit square, origin bottom left, then the quill drawn on a 1000 grid.
    ctx.scaleBy(x: s / 1000, y: s / 1000)
    // The vane: slim, from near the nib at the lower left to the tip at the upper right.
    let vane = CGMutablePath()
    vane.move(to: CGPoint(x: 330, y: 300))
    vane.addCurve(to: CGPoint(x: 840, y: 870), control1: CGPoint(x: 300, y: 560), control2: CGPoint(x: 560, y: 850))
    vane.addCurve(to: CGPoint(x: 600, y: 330), control1: CGPoint(x: 880, y: 700), control2: CGPoint(x: 780, y: 450))
    vane.addCurve(to: CGPoint(x: 330, y: 300), control1: CGPoint(x: 520, y: 300), control2: CGPoint(x: 420, y: 290))
    vane.closeSubpath()
    ctx.setFillColor(look.feather)
    ctx.addPath(vane)
    ctx.fillPath()
    // Barbs: notches cut into the lower edge of the vane.
    ctx.setStrokeColor(look.spine)
    ctx.setLineWidth(16)
    ctx.setLineCap(.round)
    for (a, b) in [((420.0, 330.0), (505.0, 292.0)), ((520.0, 440.0), (625.0, 372.0)), ((620.0, 560.0), (730.0, 480.0)),
                   ((690.0, 690.0), (790.0, 620.0))] {
        ctx.move(to: CGPoint(x: a.0, y: a.1)); ctx.addLine(to: CGPoint(x: b.0, y: b.1)); ctx.strokePath()
    }
    // The shaft runs the length of the vane and out past it to the nib.
    ctx.setLineWidth(28)
    ctx.move(to: CGPoint(x: 300, y: 270))
    ctx.addCurve(to: CGPoint(x: 815, y: 845), control1: CGPoint(x: 400, y: 480), control2: CGPoint(x: 620, y: 700))
    ctx.strokePath()
    ctx.setStrokeColor(look.feather)
    ctx.setLineWidth(30)
    ctx.move(to: CGPoint(x: 195, y: 150))
    ctx.addLine(to: CGPoint(x: 322, y: 292))
    ctx.strokePath()
    // The nib: a small pointed tip, and a drop of ink beside it.
    let nib = CGMutablePath()
    nib.move(to: CGPoint(x: 150, y: 95))
    nib.addLine(to: CGPoint(x: 215, y: 135))
    nib.addLine(to: CGPoint(x: 178, y: 188))
    nib.closeSubpath()
    ctx.setFillColor(look.feather)
    ctx.addPath(nib)
    ctx.fillPath()
    ctx.setFillColor(look.ink)
    ctx.fillEllipse(in: CGRect(x: 232, y: 90, width: 40, height: 40))
    return ctx.makeImage()!
}

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
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
