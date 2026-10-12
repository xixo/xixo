import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

let codecNames: [String: String] = [
    "avc1": "h264", "avc3": "h264", "hvc1": "hevc", "hev1": "hevc", "mp4v": "mpeg4", "jpeg": "mjpeg", "mjpa": "mjpeg",
    "ap4h": "prores", "ap4x": "prores", "apch": "prores", "apcn": "prores", "apcs": "prores", "apco": "prores",
    "av01": "av1", "vp09": "vp9", "vp08": "vp8", "s263": "h263", "h263": "h263", "png ": "png", "gif ": "gif",
    "mp4a": "aac", "aac ": "aac", ".mp3": "mp3", "mp3 ": "mp3", ".mp1": "mp1", ".mp2": "mp2", "alac": "alac",
    "ac-3": "ac3", "ec-3": "eac3", "flac": "flac", "opus": "opus", "samr": "amr_nb", "sawb": "amr_wb",
    "ima4": "adpcm_ima_qt", "ulaw": "pcm_mulaw", "alaw": "pcm_alaw", "lpcm": "pcm", "sowt": "pcm_s16le",
    "twos": "pcm_s16be", "in24": "pcm_s24be", "in32": "pcm_s32be", "fl32": "pcm_f32be", "tx3g": "mov_text",
    "c608": "eia_608", "wvtt": "webvtt",
]

let containers: [String: String] = [
    "mp4": "mov,mp4,m4a,3gp,3g2,mj2", "m4a": "mov,mp4,m4a,3gp,3g2,mj2", "m4v": "mov,mp4,m4a,3gp,3g2,mj2",
    "mov": "mov,mp4,m4a,3gp,3g2,mj2", "3gp": "mov,mp4,m4a,3gp,3g2,mj2", "3g2": "mov,mp4,m4a,3gp,3g2,mj2",
    "m4b": "mov,mp4,m4a,3gp,3g2,mj2", "mp3": "mp3", "wav": "wav", "aif": "aiff", "aiff": "aiff", "aifc": "aiff",
    "caf": "caf", "flac": "flac", "aac": "aac", "adts": "aac", "amr": "amr", "ac3": "ac3",
]

let mediaTags = ["title", "artist", "album_artist", "album", "date", "genre", "composer", "comment"]

let tagKeys: [String: String] = [
    "title": "title", "©nam": "title", "TIT2": "title", "TT2": "title",
    "artist": "artist", "©ART": "artist", "TPE1": "artist", "TP1": "artist",
    "aART": "album_artist", "TPE2": "album_artist", "TP2": "album_artist",
    "albumName": "album", "©alb": "album", "TALB": "album", "TAL": "album",
    "creationDate": "date", "©day": "date", "TDRC": "date", "TYER": "date", "TYE": "date",
    "©gen": "genre", "gnre": "genre", "TCON": "genre", "TCO": "genre", "type": "genre",
    "©wrt": "composer", "TCOM": "composer", "TCM": "composer",
    "©cmt": "comment", "COMM": "comment", "COM": "comment",
]

func fourCC(_ code: FourCharCode) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xff) }
    let printable = bytes.allSatisfy { $0 >= 32 && $0 < 127 }

    return printable ? String(decoding: bytes, as: UTF8.self) : String(code)
}

func codecName(_ description: CMFormatDescription) -> String {
    let code = fourCC(CMFormatDescriptionGetMediaSubType(description))

    return codecNames[code] ?? code.trimmingCharacters(in: .whitespaces).lowercased()
}

func pcmName(_ basic: AudioStreamBasicDescription) -> String {
    let bits = Int(basic.mBitsPerChannel)
    let float = basic.mFormatFlags & kAudioFormatFlagIsFloat != 0
    let signed = basic.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
    let order = basic.mFormatFlags & kAudioFormatFlagIsBigEndian != 0 ? "be" : "le"

    if bits == 8 && !float {
        return signed ? "pcm_s8" : "pcm_u8"
    }

    return "pcm_\(float ? "f" : signed ? "s" : "u")\(bits)\(order)"
}

func asset(_ arguments: Arguments) -> AVURLAsset {
    AVURLAsset(url: arguments.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
}

func playableSeconds(_ held: AVURLAsset) async throws -> Double {
    let duration = try await held.load(.duration)
    let seconds = CMTimeGetSeconds(duration)

    return seconds.isFinite && seconds > 0 ? seconds : 0
}

func tagged(_ held: AVURLAsset) async throws -> [String: String] {
    var tags: [String: String] = [:]
    let items = try await held.load(.metadata)

    for item in items {
        let key = (item.commonKey?.rawValue).flatMap { tagKeys[$0] }
            ?? (item.key as? String).flatMap { tagKeys[$0] }
            ?? (item.key as? NSNumber).flatMap { tagKeys[fourCC(FourCharCode(truncating: $0))] }

        guard let key, tags[key] == nil else { continue }

        if let value = try? await item.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            tags[key] = value
        }
    }

    return tags
}

func probe(_ arguments: Arguments) async throws -> Any {
    let held = asset(arguments)
    let tracks = try await held.load(.tracks)
    let seconds = try await playableSeconds(held)

    guard !tracks.isEmpty else { throw Failure("AVFoundation found no audio or video in the file") }

    var streams: [[String: Any]] = []

    for track in tracks.prefix(8) {
        let type = track.mediaType
        let descriptions = try await track.load(.formatDescriptions)
        var stream: [String: Any] = [:]

        switch type {
        case .video: stream["type"] = "video"
        case .audio: stream["type"] = "audio"
        case .subtitle, .closedCaption, .text: stream["type"] = "subtitle"
        default: stream["type"] = "data"
        }

        if let description = descriptions.first {
            stream["codec"] = codecName(description)

            if type == .audio, let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                stream["channels"] = Int(basic.mChannelsPerFrame)
                stream["sample_rate"] = whole(basic.mSampleRate)

                if basic.mFormatID == kAudioFormatLinearPCM {
                    stream["codec"] = pcmName(basic)
                }
            }
        }

        if type == .video {
            let size = try await track.load(.naturalSize)
            stream["width"] = whole(size.width)
            stream["height"] = whole(size.height)
        }

        if let language = try await track.load(.languageCode), !language.isEmpty {
            stream["language"] = language
        }

        streams.append(stream)
    }

    var answer: [String: Any] = ["streams": streams, "duration": (seconds * 100).rounded() / 100]
    let ext = arguments.url.pathExtension.lowercased()
    answer["format"] = containers[ext] ?? ext

    if seconds > 0, let size = try? FileManager.default.attributesOfItem(atPath: arguments.input)[.size] as? Int {
        answer["bit_rate"] = whole(Double(size) * 8 / seconds)
    }

    answer["tags"] = try await tagged(held)

    return answer
}

func still(_ held: AVURLAsset, at seconds: Double) async throws -> CGImage {
    let generator = AVAssetImageGenerator(asset: held)
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
    generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

    return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
}

func videoThumbnail(_ arguments: Arguments, out: String, width: Int, fit: Bool) async throws -> [String: Any] {
    let held = asset(arguments)
    let seconds = try await playableSeconds(held)
    var image: CGImage

    do {
        image = try await still(held, at: seconds > 1 ? 1 : 0)
    } catch {
        image = try await still(held, at: 0)
    }

    let made = try scaled(image, width: width, fit: fit, crop: false)
    try writeJPEG(made, to: out)

    return ["path": out, "width": made.width, "height": made.height]
}

func videoFrames(_ arguments: Arguments, out: String, width: Int) async throws -> [[String: Any]] {
    let held = asset(arguments)
    var made: [[String: Any]] = []

    for (index, at) in try arguments.numbers("at").enumerated() {
        guard let image = try? await still(held, at: at) else { continue }

        let path = (out as NSString).appendingPathComponent("frame-\(index).jpg")
        try writeJPEG(try exactWidth(image, width, even: true), to: path)
        made.append(["index": index, "at": at, "path": path])
    }

    return made
}

func thumbnail(_ arguments: Arguments) async throws -> Any {
    let out = try arguments.path("out")
    let width = try arguments.int("width", 320)
    let fit = arguments.options["fit"] == "true"

    switch try arguments.string("kind") {
    case "image": return try imageThumbnail(arguments, out: out, width: width, fit: fit, crop: arguments.options["crop"] == "top")
    case "pdf": return try pdfThumbnail(arguments, out: out, width: width, fit: fit)
    case "video": return try await videoThumbnail(arguments, out: out, width: width, fit: fit)
    case "audio": return try await waveform(arguments, out: out)
    default: throw Failure("--kind is image, pdf, video, or audio")
    }
}

func frames(_ arguments: Arguments) async throws -> Any {
    let out = try arguments.path("out")
    let width = try arguments.int("width", 768)

    if arguments.options["index"] != nil {
        return ["frames": try animationFrames(arguments, out: out, width: width)]
    }

    return ["frames": try await videoFrames(arguments, out: out, width: width)]
}

func reader(_ held: AVURLAsset, rate: Double, channels: Int, seconds: Double) async throws -> (AVAssetReader, AVAssetReaderAudioMixOutput) {
    let tracks = try await held.loadTracks(withMediaType: .audio)

    guard !tracks.isEmpty else { throw Failure("AVFoundation found no audio in the file") }

    let reading = try AVAssetReader(asset: held)
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: rate,
        AVNumberOfChannelsKey: channels,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
    output.alwaysCopiesSampleData = false

    guard reading.canAdd(output) else { throw Failure("AVFoundation cannot decode the audio") }

    reading.add(output)
    reading.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))

    guard reading.startReading() else {
        throw Failure("AVFoundation cannot decode the audio: \(reading.error?.localizedDescription ?? "unknown")")
    }

    return (reading, output)
}

func samples(_ held: AVURLAsset, rate: Double, channels: Int, seconds: Double, each: ([Float]) throws -> Void) async throws {
    let (reading, output) = try await reader(held, rate: rate, channels: channels, seconds: seconds)

    while let buffer = output.copyNextSampleBuffer() {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }

        let length = CMBlockBufferGetDataLength(block)
        var chunk = [Float](repeating: 0, count: length / 4)

        let status = chunk.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }

            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }

        if status == kCMBlockBufferNoErr {
            try each(chunk)
        }
    }

    if reading.status == .failed {
        throw Failure("AVFoundation stopped decoding: \(reading.error?.localizedDescription ?? "unknown")")
    }
}

func heard(_ arguments: Arguments) async throws -> Any {
    let out = try arguments.path("out")
    let seconds = Double(try arguments.int("seconds", 3600))
    let held = asset(arguments)

    guard FileManager.default.createFile(atPath: out, contents: nil),
          let file = FileHandle(forWritingAtPath: out)
    else { throw Failure("could not write \(out)") }

    defer { try? file.close() }

    file.write(Data(count: 44))
    var written = 0

    try await samples(held, rate: 16000, channels: 1, seconds: seconds) { chunk in
        let values = chunk.map { Int16($0.isFinite ? max(-1, min(1, $0)) * 32767 : 0).littleEndian }
        let pcm = values.withUnsafeBufferPointer { Data(buffer: $0) }

        file.write(pcm)
        written += pcm.count
    }

    var header = Data()
    let little = { (value: UInt32, size: Int) in
        var held = value.littleEndian
        withUnsafeBytes(of: &held) { header.append(contentsOf: $0.prefix(size)) }
    }

    header.append(contentsOf: Array("RIFF".utf8))
    little(UInt32(36 + written), 4)
    header.append(contentsOf: Array("WAVEfmt ".utf8))
    little(16, 4)
    little(1, 2)
    little(1, 2)
    little(16000, 4)
    little(32000, 4)
    little(2, 2)
    little(16, 2)
    header.append(contentsOf: Array("data".utf8))
    little(UInt32(written), 4)

    try file.seek(toOffset: 0)
    file.write(header)

    return ["path": out, "seconds": Double(written / 2) / 16000]
}

func waveform(_ arguments: Arguments, out: String) async throws -> [String: Any] {
    let held = asset(arguments)
    let seconds = min(try await playableSeconds(held), 3600)
    let wide = max(1000, min(2000, Int((1000 + seconds / 3600 * 1000).rounded())))
    let high = wide / 3
    let rate = 8000.0
    var peaks = [Float](repeating: 0, count: wide)
    let total = max(1, Int(seconds * rate))
    var at = 0

    try await samples(held, rate: rate, channels: 1, seconds: max(seconds, 1)) { chunk in
        for sample in chunk {
            let column = min(wide - 1, at * wide / total)
            peaks[column] = sample.isFinite ? max(peaks[column], abs(sample)) : peaks[column]
            at += 1
        }
    }

    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: wide, height: high, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw Failure("could not make a drawing surface") }

    context.setFillColor(CGColor(srgbRed: 0x1b / 255, green: 0x20 / 255, blue: 0x24 / 255, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: wide, height: high))
    context.setFillColor(CGColor(srgbRed: 0xc9 / 255, green: 0xa8 / 255, blue: 0x6a / 255, alpha: 1))

    let middle = Double(high) / 2

    for (column, peak) in peaks.enumerated() {
        let reach = Double(min(1, peak)).squareRoot() * middle

        if reach > 0 {
            context.fill(CGRect(x: Double(column), y: middle - reach, width: 1, height: reach * 2))
        }
    }

    guard let image = context.makeImage() else { throw Failure("could not draw the waveform") }

    try writeJPEG(image, to: out, quality: 0.85)

    return ["path": out, "width": wide, "height": high]
}
