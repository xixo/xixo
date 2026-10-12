import CoreGraphics
import Foundation
import PDFKit

let mostOutline = 200

func openPDF(_ url: URL) throws -> PDFDocument {
    guard let document = PDFDocument(url: url) else { throw Failure("PDFKit could not open the pdf") }

    if document.isLocked && !document.unlock(withPassword: "") {
        throw Failure("the pdf is encrypted with a password")
    }

    return document
}

func openPages(_ url: URL) throws -> CGPDFDocument {
    guard let document = CGPDFDocument(url as CFURL) else { throw Failure("Core Graphics could not open the pdf") }

    if document.isEncrypted && !document.isUnlocked && !document.unlockWithPassword("") {
        throw Failure("the pdf is encrypted with a password")
    }

    return document
}

let paperSizes: [(String, Double, Double)] = [
    ("letter", 612, 792), ("legal", 612, 1008), ("A4", 595.276, 841.89), ("A3", 841.89, 1190.55), ("A5", 419.528, 595.276),
]

func pageSize(_ page: PDFPage) -> String {
    let box = page.bounds(for: .mediaBox)
    let width = box.width
    let height = box.height
    let shown = { (value: Double) -> String in
        value == value.rounded() ? String(Int(value)) : String(format: "%.3f", value)
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
    }
    var said = "\(shown(width)) x \(shown(height)) pts"

    if let paper = paperSizes.first(where: { abs($0.1 - min(width, height)) < 2 && abs($0.2 - max(width, height)) < 2 }) {
        said += " (\(paper.0))"
    }

    return said
}

func pdfDate(_ value: Any?) -> String? {
    guard let date = value as? Date else { return nil }

    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.timeZone = TimeZone(identifier: "UTC")
    format.dateFormat = "EEE MMM d HH:mm:ss yyyy 'UTC'"

    return format.string(from: date)
}

func outline(_ document: PDFDocument) -> [[String: Any]] {
    var found: [[String: Any]] = []

    func visit(_ node: PDFOutline, depth: Int) {
        for at in 0..<node.numberOfChildren {
            guard found.count < mostOutline, let child = node.child(at: at) else { return }

            if let label = child.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty,
               let page = child.destination?.page {
                found.append(["name": label, "page": document.index(for: page) + 1])
            }

            if depth < 3 {
                visit(child, depth: depth + 1)
            }
        }
    }

    if let root = document.outlineRoot {
        visit(root, depth: 1)
    }

    return found
}

func readPDF(_ arguments: Arguments) throws -> Any {
    let document = try openPDF(arguments.url)
    let attributes = document.documentAttributes ?? [:]
    var info: [String: Any] = ["pages": document.pageCount]

    if let title = attributes[PDFDocumentAttribute.titleAttribute] as? String, !title.isEmpty {
        info["title"] = title
    }

    if let author = attributes[PDFDocumentAttribute.authorAttribute] as? String, !author.isEmpty {
        info["author"] = author
    }

    if let created = pdfDate(attributes[PDFDocumentAttribute.creationDateAttribute]) {
        info["creationdate"] = created
    }

    if let first = document.page(at: 0) {
        info["page_size"] = pageSize(first)
    }

    var pages: [String] = []

    for index in 0..<document.pageCount {
        pages.append(document.page(at: index)?.string ?? "")
    }

    return ["info": info, "pages": pages, "outline": outline(document)]
}

func renderPage(_ document: CGPDFDocument, _ number: Int, width: Int? = nil, longest: Int? = nil, dpi: Double? = nil) throws -> CGImage {
    guard let page = document.page(at: number) else { throw Failure("the pdf has no page \(number)") }

    let box = page.getBoxRect(.cropBox)
    let turned = page.rotationAngle % 180 != 0
    let pointsWide = turned ? box.height : box.width
    let pointsHigh = turned ? box.width : box.height

    guard pointsWide.isFinite, pointsHigh.isFinite, pointsWide > 0, pointsHigh > 0 else { throw Failure("page \(number) has no size") }

    var scale = 1.0

    if let dpi {
        scale = dpi / 72
    } else if let width {
        scale = Double(width) / pointsWide
    } else if let longest {
        scale = Double(longest) / max(pointsWide, pointsHigh)
    }

    scale = min(scale, Double(mostPixels) / max(pointsWide, pointsHigh))

    let pixelsWide = max(1, Int((pointsWide * scale).rounded()))
    let pixelsHigh = max(1, Int((pointsHigh * scale).rounded()))

    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw Failure("could not make a drawing surface") }

    let target = CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh)
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.fill(target)
    context.interpolationQuality = .high
    context.scaleBy(x: scale, y: scale)
    context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: pointsWide, height: pointsHigh),
                                                 rotate: 0, preserveAspectRatio: true))
    context.clip(to: box)
    context.drawPDFPage(page)

    guard let image = context.makeImage() else { throw Failure("could not draw page \(number)") }

    return image
}

func pdfThumbnail(_ arguments: Arguments, out: String, width: Int, fit: Bool) throws -> [String: Any] {
    let document = try openPages(arguments.url)
    let image = fit ? try renderPage(document, 1, longest: width) : try renderPage(document, 1, width: width)

    try writeJPEG(image, to: out)

    return ["path": out, "width": image.width, "height": image.height]
}
