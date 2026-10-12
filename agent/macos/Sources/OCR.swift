import CoreGraphics
import Foundation
import ImageIO
import Vision

let ocrDPI = 200.0

struct Line {
    var text: String
    var box: CGRect
}

func read(_ image: CGImage, orientation: CGImagePropertyOrientation = .up) throws -> [Line] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true

    if #available(macOS 13.0, *) {
        request.automaticallyDetectsLanguage = true
    }

    let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
    try handler.perform([request])

    let found: [Line] = (request.results ?? []).compactMap { observation in
        guard let best = observation.topCandidates(1).first else { return nil }

        let text = best.string.trimmingCharacters(in: .whitespacesAndNewlines)

        return text.isEmpty ? nil : Line(text: text, box: observation.boundingBox)
    }

    return joined(found)
}

func joined(_ found: [Line]) -> [Line] {
    var rows: [Line] = []

    for line in found.sorted(by: { $0.box.midY > $1.box.midY }) {
        if let last = rows.last, abs(last.box.midY - line.box.midY) < min(last.box.height, line.box.height) / 2 {
            var row = last
            let left = row.box.minX <= line.box.minX
            row.text = left ? row.text + " " + line.text : line.text + " " + row.text
            row.box = row.box.union(line.box)
            rows[rows.count - 1] = row
        } else {
            rows.append(line)
        }
    }

    return rows
}

func page(_ number: Int, _ lines: [Line]) -> [String: Any] {
    [
        "page": number,
        "text": lines.map(\.text).joined(separator: "\n"),
        "lines": lines.map { line in
            [
                "text": line.text,
                "box": [line.box.minX, 1 - line.box.maxY, line.box.width, line.box.height].map { NSDecimalNumber(string: String(format: "%.4f", $0)) },
            ] as [String: Any]
        },
    ]
}

func recognize(_ arguments: Arguments) throws -> Any {
    if arguments.options["kind"] == "pdf" {
        let document = try openPages(arguments.url)
        let last = min(document.numberOfPages, try arguments.int("pages", document.numberOfPages))
        var pages: [[String: Any]] = []

        for number in stride(from: 1, through: last, by: 1) {
            let image = try renderPage(document, number, dpi: ocrDPI)
            pages.append(page(number, try read(image)))
        }

        return ["pages": pages, "of": document.numberOfPages]
    }

    let held = try source(arguments.url)
    let size = try storedSize(held)
    let image = try picture(held, 0, longest: max(size.width, size.height))

    return ["pages": [page(1, try read(image))], "of": 1]
}
