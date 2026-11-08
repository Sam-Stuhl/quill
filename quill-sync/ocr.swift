// ocr.swift: handwriting and printed text of a PDF, one string per page, as JSON.
//   swift ocr.swift FILE.pdf
// Apple's Vision (accurate mode) on each page rendered at about 2000 px, in reading
// order (top to bottom, then left to right within a line). Used by quill-sync's
// connect.py; runs on the mini's CPU, so it is slow and is only called once a note
// has been quiet for a while.
import Foundation
import PDFKit
import Vision

guard CommandLine.arguments.count == 2, let doc = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1])) else {
    FileHandle.standardError.write(Data("usage: ocr.swift FILE.pdf\n".utf8))
    exit(2)
}

func render(_ page: PDFPage) -> CGImage? {
    let box = page.bounds(for: .mediaBox)
    let scale = min(2.5, 2000 / max(box.width, box.height))
    let w = Int(box.width * scale), h = Int(box.height * scale)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: ctx)
    return ctx.makeImage()
}

func lines(_ image: CGImage) -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["en-US"]
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do { try handler.perform([request]) } catch { return "" }
    let found = (request.results ?? []).compactMap { obs -> (CGRect, String)? in
        guard let top = obs.topCandidates(1).first, top.confidence > 0.3 else { return nil }
        return (obs.boundingBox, top.string)
    }
    // Vision's origin is bottom left: higher y is higher on the page. Group into rows.
    let sorted = found.sorted { $0.0.midY > $1.0.midY }
    var rows: [[(CGRect, String)]] = []
    for item in sorted {
        if let last = rows.last, abs(last[0].0.midY - item.0.midY) < max(item.0.height, last[0].0.height) * 0.6 {
            rows[rows.count - 1].append(item)
        } else {
            rows.append([item])
        }
    }
    return rows.map { $0.sorted { $0.0.minX < $1.0.minX }.map { $0.1 }.joined(separator: " ") }
        .joined(separator: "\n")
}

var pages: [String] = []
for i in 0..<doc.pageCount {
    autoreleasepool {
        if let page = doc.page(at: i), let image = render(page) {
            pages.append(lines(image))
        } else {
            pages.append("")
        }
    }
}
let data = try JSONSerialization.data(withJSONObject: pages)
FileHandle.standardOutput.write(data)
