import AVFoundation
import Foundation
import ImageIO
import PDFKit

let exifNames: [String: String] = [
    "DateTimeOriginal": "DateTimeOriginal", "DateTimeDigitized": "CreateDate", "ExposureTime": "ExposureTime",
    "FNumber": "FNumber", "ISOSpeedRatings": "ISO", "FocalLength": "FocalLength", "FocalLenIn35mmFilm": "FocalLengthIn35mmFormat",
    "LensMake": "LensMake", "LensModel": "LensModel", "ExposureProgram": "ExposureProgram", "ExposureBiasValue": "ExposureCompensation",
    "MeteringMode": "MeteringMode", "Flash": "Flash", "WhiteBalance": "WhiteBalance", "ColorSpace": "ColorSpace",
    "UserComment": "UserComment", "BodySerialNumber": "SerialNumber", "OffsetTimeOriginal": "OffsetTimeOriginal",
    "SceneCaptureType": "SceneCaptureType", "ShutterSpeedValue": "ShutterSpeedValue", "ApertureValue": "ApertureValue",
]

let tiffNames: [String: String] = [
    "Make": "Make", "Model": "Model", "Software": "Software", "DateTime": "ModifyDate", "Artist": "Artist",
    "Copyright": "Copyright", "ImageDescription": "ImageDescription", "HostComputer": "HostComputer",
]

func shownNumber(_ value: Any) -> Any {
    if let number = value as? NSNumber {
        let double = number.doubleValue

        if double == double.rounded() && abs(double) < 1e15 {
            return Int(double)
        }

        return (double * 1e6).rounded() / 1e6
    }

    if let list = value as? [Any] {
        return list.map { "\(shownNumber($0))" }.joined(separator: ", ")
    }

    return "\(value)"
}

func exposure(_ value: Any) -> Any {
    guard let seconds = (value as? NSNumber)?.doubleValue, seconds > 0 else { return shownNumber(value) }

    return seconds < 1 && seconds > 1e-9 ? "1/\(whole(1 / seconds))" : shownNumber(value)
}

func imageMetadata(_ arguments: Arguments) throws -> [[Any]] {
    let held = try source(arguments.url)
    let found = properties(held)
    var listed: [[Any]] = []

    if let size = try? storedSize(held) {
        listed.append(["ImageWidth", size.width])
        listed.append(["ImageHeight", size.height])
        listed.append(["ImageSize", "\(size.width)x\(size.height)"])
        listed.append(["Megapixels", (Double(size.width * size.height) / 1e5).rounded() / 10])
    }

    if let model = found[kCGImagePropertyColorModel as String] as? String {
        listed.append(["ColorMode", model])
    }

    if let profile = found[kCGImagePropertyProfileName as String] as? String {
        listed.append(["ProfileDescription", profile])
    }

    if let orientation = found[kCGImagePropertyOrientation as String] as? Int, orientation != 1 {
        listed.append(["Orientation", orientation])
    }

    let tiff = found[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]

    for key in tiff.keys.sorted() {
        if let name = tiffNames[key], let value = tiff[key] {
            listed.append([name, shownNumber(value)])
        }
    }

    let exif = found[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]

    for key in exif.keys.sorted() {
        if let name = exifNames[key], let value = exif[key] {
            listed.append([name, key == "ExposureTime" ? exposure(value) : shownNumber(value)])
        }
    }

    if let place = location(found) {
        listed.append(["GPSLatitude", place["latitude"] ?? 0])
        listed.append(["GPSLongitude", place["longitude"] ?? 0])

        if let gps = found[kCGImagePropertyGPSDictionary as String] as? [String: Any],
           let altitude = gps[kCGImagePropertyGPSAltitude as String] {
            listed.append(["GPSAltitude", shownNumber(altitude)])
        }
    }

    let count = CGImageSourceGetCount(held)

    if count > 1 {
        listed.append(["FrameCount", count])
    }

    return listed
}

func pdfMetadata(_ arguments: Arguments) throws -> [[Any]] {
    let document = try openPDF(arguments.url)
    let attributes = document.documentAttributes ?? [:]
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.timeZone = TimeZone(identifier: "UTC")
    format.dateFormat = "yyyy:MM:dd HH:mm:ssXXX"
    var listed: [[Any]] = []

    let named: [(PDFDocumentAttribute, String)] = [
        (.titleAttribute, "Title"), (.authorAttribute, "Author"), (.subjectAttribute, "Subject"),
        (.creatorAttribute, "Creator"), (.producerAttribute, "Producer"), (.creationDateAttribute, "CreateDate"),
        (.modificationDateAttribute, "ModifyDate"), (.keywordsAttribute, "Keywords"),
    ]

    for (attribute, name) in named {
        switch attributes[attribute] {
        case let date as Date: listed.append([name, format.string(from: date)])
        case let list as [Any]: listed.append([name, list.map { "\($0)" }.joined(separator: ", ")])
        case let value?: listed.append([name, "\(value)"])
        default: break
        }
    }

    listed.append(["PageCount", document.pageCount])

    if document.isEncrypted {
        listed.append(["Encryption", "encrypted"])
    }

    return listed
}

func mediaMetadata(_ arguments: Arguments) async throws -> [[Any]] {
    let held = asset(arguments)
    let seconds = try await playableSeconds(held)
    var listed: [[Any]] = []

    if seconds > 0 {
        if seconds < 30 {
            listed.append(["Duration", String(format: "%.2f s", seconds)])
        } else {
            let whole = Int(seconds.rounded())
            listed.append(["Duration", String(format: "%d:%02d:%02d", whole / 3600, whole % 3600 / 60, whole % 60)])
        }
    }

    for track in try await held.load(.tracks) {
        let descriptions = try await track.load(.formatDescriptions)

        guard let description = descriptions.first else { continue }

        if track.mediaType == .video {
            let size = try await track.load(.naturalSize)
            listed.append(["ImageWidth", whole(size.width)])
            listed.append(["ImageHeight", whole(size.height)])
            listed.append(["CompressorID", fourCC(CMFormatDescriptionGetMediaSubType(description))])

            let rate = try await track.load(.nominalFrameRate)

            if rate > 0 {
                listed.append(["VideoFrameRate", (Double(rate) * 1000).rounded() / 1000])
            }
        } else if track.mediaType == .audio {
            listed.append(["AudioFormat", fourCC(CMFormatDescriptionGetMediaSubType(description))])

            if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                listed.append(["AudioChannels", Int(basic.mChannelsPerFrame)])
                listed.append(["AudioSampleRate", whole(basic.mSampleRate)])
            }
        }
    }

    let named = ["title": "Title", "artist": "Artist", "album_artist": "AlbumArtist", "album": "Album", "date": "CreateDate",
                 "genre": "Genre", "composer": "Composer", "comment": "Comment"]
    let tags = try await tagged(held)

    for tag in mediaTags {
        if let value = tags[tag], let name = named[tag] {
            listed.append([name, value])
        }
    }

    for item in try await held.load(.metadata) {
        guard let identifier = item.identifier?.rawValue else { continue }

        let name: String? = switch identifier {
        case "mdta/com.apple.quicktime.make": "Make"
        case "mdta/com.apple.quicktime.model": "Model"
        case "mdta/com.apple.quicktime.software": "Software"
        case "mdta/com.apple.quicktime.location.ISO6709": "GPSCoordinates"
        case "mdta/com.apple.quicktime.creationdate": "CreationDate"
        default: nil
        }

        if let name, let value = try? await item.load(.stringValue), !value.isEmpty {
            listed.append([name, value])
        }
    }

    return listed
}

func metadata(_ arguments: Arguments) async throws -> Any {
    switch try arguments.string("kind") {
    case "image": return ["tags": try imageMetadata(arguments)]
    case "pdf": return ["tags": try pdfMetadata(arguments)]
    case "media": return ["tags": try await mediaMetadata(arguments)]
    default: throw Failure("--kind is image, pdf, or media")
    }
}
