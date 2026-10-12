import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let mostPixels = 16384

func source(_ url: URL) throws -> CGImageSource {
    guard let held = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
          CGImageSourceGetCount(held) > 0
    else { throw Failure("ImageIO could not read the image") }

    return held
}

func properties(_ held: CGImageSource, _ index: Int = 0) -> [String: Any] {
    CGImageSourceCopyPropertiesAtIndex(held, index, nil) as? [String: Any] ?? [:]
}

func storedSize(_ held: CGImageSource, _ index: Int = 0) throws -> (width: Int, height: Int) {
    let found = properties(held, index)

    guard let width = found[kCGImagePropertyPixelWidth as String] as? Int,
          let height = found[kCGImagePropertyPixelHeight as String] as? Int,
          width > 0, height > 0
    else { throw Failure("the image names no width and height") }

    return (width, height)
}

func orientedSize(_ held: CGImageSource, _ index: Int = 0) throws -> (width: Int, height: Int) {
    let size = try storedSize(held, index)
    let turned = (properties(held, index)[kCGImagePropertyOrientation as String] as? Int ?? 1) >= 5

    return turned ? (size.height, size.width) : size
}

func picture(_ held: CGImageSource, _ index: Int, longest: Int) throws -> CGImage {
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: max(1, min(longest, mostPixels)),
    ]

    guard let image = CGImageSourceCreateThumbnailAtIndex(held, index, options as CFDictionary) else {
        throw Failure("ImageIO could not draw the image")
    }

    return image
}

func flattened(_ image: CGImage, width: Int, height: Int, crop: CGRect? = nil) throws -> CGImage {
    let width = max(1, min(width, mostPixels))
    let height = max(1, min(height, mostPixels))

    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw Failure("could not make a drawing surface") }

    context.interpolationQuality = .high
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let drawn = crop ?? CGRect(x: 0, y: 0, width: width, height: height)
    context.draw(image, in: drawn)

    guard let made = context.makeImage() else { throw Failure("could not draw the image") }

    return made
}

func writeJPEG(_ image: CGImage, to path: String, quality: Double = 0.8) throws {
    let url = URL(fileURLWithPath: path)

    guard let target = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw Failure("could not write \(path)")
    }

    CGImageDestinationAddImage(target, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)

    guard CGImageDestinationFinalize(target) else { throw Failure("could not write \(path)") }
}

func scaled(_ image: CGImage, width: Int, fit: Bool, crop: Bool) throws -> CGImage {
    let w = Double(image.width)
    let h = Double(image.height)
    let bound = Double(width)

    if crop {
        let scale = bound / min(w, h)
        let drawnWidth = w * scale
        let drawnHeight = h * scale
        let side = Int(bound.rounded())
        let rect = CGRect(x: (bound - drawnWidth) / 2, y: bound - drawnHeight, width: drawnWidth, height: drawnHeight)

        return try flattened(image, width: side, height: side, crop: rect)
    }

    let scale = fit ? min(1, bound / max(w, h)) : min(1, bound / w)
    let outWidth = Int((w * scale).rounded())
    let outHeight = Int((h * scale).rounded())

    return try flattened(image, width: outWidth, height: outHeight)
}

func exactWidth(_ image: CGImage, _ width: Int, even: Bool = false) throws -> CGImage {
    var height = Int((Double(image.height) * Double(width) / Double(image.width)).rounded())

    if even && height % 2 == 1 {
        height += 1
    }

    return try flattened(image, width: width, height: max(height, 1))
}

func imageThumbnail(_ arguments: Arguments, out: String, width: Int, fit: Bool, crop: Bool) throws -> [String: Any] {
    let held = try source(arguments.url)
    let size = try orientedSize(held)
    let longest = Double(max(size.width, size.height))
    let bound = Double(width)
    let shrink = crop ? bound / Double(min(size.width, size.height))
        : fit ? bound / longest : bound / Double(size.width)
    let image = try picture(held, 0, longest: Int((longest * min(shrink, 1)).rounded(.up)))
    let made = try scaled(image, width: width, fit: fit, crop: crop)

    try writeJPEG(made, to: out)

    return ["path": out, "width": made.width, "height": made.height]
}

func describeImage(_ arguments: Arguments) throws -> Any {
    let held = try source(arguments.url)
    let size = try storedSize(held)
    let count = CGImageSourceGetCount(held)
    var answer: [String: Any] = ["width": size.width, "height": size.height, "frames": count]

    answer["deviation"] = try deviation(held, size: size)
    answer["location"] = location(properties(held)) ?? NSNull()

    return answer
}

func deviation(_ held: CGImageSource, size: (width: Int, height: Int)) throws -> Double {
    if size.width * size.height < 2 {
        return 0
    }

    let longest = min(max(size.width, size.height), 4096)
    let image = try picture(held, 0, longest: longest)
    let width = image.width
    let height = image.height
    let bands = 3

    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
          let pixels = context.data
    else { throw Failure("could not make a drawing surface") }

    context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    let bytes = pixels.bindMemory(to: UInt8.self, capacity: width * height * 4)
    var sum = 0.0
    var squares = 0.0

    for at in 0..<(width * height) {
        for band in 0..<bands {
            let value = Double(bytes[at * 4 + band])
            sum += value
            squares += value * value
        }
    }

    let count = Double(width * height * bands)
    let mean = sum / count
    let variance = max(0, squares / count - mean * mean)

    return (variance.squareRoot() * 1e6).rounded() / 1e6
}

func location(_ found: [String: Any]) -> [String: Double]? {
    guard let gps = found[kCGImagePropertyGPSDictionary as String] as? [String: Any],
          var latitude = gps[kCGImagePropertyGPSLatitude as String] as? Double,
          var longitude = gps[kCGImagePropertyGPSLongitude as String] as? Double
    else { return nil }

    if (gps[kCGImagePropertyGPSLatitudeRef as String] as? String)?.uppercased() == "S" {
        latitude = -latitude
    }

    if (gps[kCGImagePropertyGPSLongitudeRef as String] as? String)?.uppercased() == "W" {
        longitude = -longitude
    }

    if latitude == 0 && longitude == 0 {
        return nil
    }

    return ["latitude": (latitude * 1e6).rounded() / 1e6, "longitude": (longitude * 1e6).rounded() / 1e6]
}

func animationFrames(_ arguments: Arguments, out: String, width: Int) throws -> [[String: Any]] {
    let held = try source(arguments.url)
    let count = CGImageSourceGetCount(held)
    var made: [[String: Any]] = []

    for number in try arguments.numbers("index") {
        let index = Int(number)

        guard index < count else { continue }

        let size = try orientedSize(held, index)
        let image = try exactWidth(try picture(held, index, longest: max(size.width, size.height)), width)
        let path = (out as NSString).appendingPathComponent("frame-\(index).jpg")

        try writeJPEG(image, to: path)
        made.append(["index": index, "path": path])
    }

    return made
}
