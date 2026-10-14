import Foundation

struct Failure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

let usage = """
usage: xixo-mac-reader <command> <absolute input path> [--name value ...]

commands:
  pdf        the text of each page, the document's fields, and its outline
  ocr        the text Vision reads in an image, or in a pdf's pages (--pages N)
  image      dimensions, frames, pixel deviation, and location
  thumbnail  a JPEG of an image, pdf, video, or audio (--kind --out --width [--fit] [--crop top])
  frames     JPEG frames of a video (--at s,s) or an animation (--index n,n) (--out --width)
  media      the containers, streams, duration, and tags of audio or video
  audio      16 kHz mono WAV of --seconds of audio from --from, the start by default (--out)
  signal     loudness, silences, and spectrum of the first --seconds of audio
  metadata   the fields an image, pdf, or media file names about itself (--kind)
"""

struct Arguments {
    let command: String
    let input: String
    let options: [String: String]

    init(_ raw: [String]) throws {
        guard raw.count >= 2 else { throw Failure(usage) }

        command = raw[0]

        guard raw[1].hasPrefix("/") else { throw Failure("the input must be an absolute path") }

        input = URL(fileURLWithPath: raw[1]).resolvingSymlinksInPath().path

        guard FileManager.default.isReadableFile(atPath: input) else { throw Failure("cannot read \(input)") }

        var held: [String: String] = [:]
        var at = 2

        while at < raw.count {
            let key = raw[at]

            guard key.hasPrefix("--"), at + 1 < raw.count else { throw Failure("expected --name value, found \(key)") }

            held[String(key.dropFirst(2))] = raw[at + 1]
            at += 2
        }

        options = held
    }

    var url: URL { URL(fileURLWithPath: input) }

    func string(_ name: String) throws -> String {
        guard let value = options[name], !value.isEmpty else { throw Failure("--\(name) is required") }

        return value
    }

    func path(_ name: String) throws -> String {
        let value = try string(name)

        guard value.hasPrefix("/") else { throw Failure("--\(name) must be an absolute path") }

        return value
    }

    func int(_ name: String, _ fallback: Int) throws -> Int {
        guard let value = options[name] else { return fallback }
        guard let number = Int(value), number > 0 else { throw Failure("--\(name) must be a positive whole number") }

        return number
    }

    func numbers(_ name: String) throws -> [Double] {
        let value = try string(name)

        return try value.split(separator: ",").map { part in
            guard let number = Double(part), number.isFinite, number >= 0 else { throw Failure("--\(name) holds \(part)") }

            return number
        }
    }
}

func whole(_ value: Double) -> Int {
    guard value.isFinite, abs(value) < 1e15 else { return 0 }

    return Int(value.rounded())
}

func emit(_ value: Any) throws {
    guard JSONSerialization.isValidJSONObject(value) else { throw Failure("the answer could not be written as JSON") }

    let data = try JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func answer(_ arguments: Arguments) async throws -> Any {
    switch arguments.command {
    case "pdf": return try readPDF(arguments)
    case "ocr": return try recognize(arguments)
    case "image": return try describeImage(arguments)
    case "thumbnail": return try await thumbnail(arguments)
    case "frames": return try await frames(arguments)
    case "media": return try await probe(arguments)
    case "audio": return try await heard(arguments)
    case "signal": return try await signal(arguments)
    case "metadata": return try await metadata(arguments)
    default: throw Failure(usage)
    }
}

func said(_ error: Error) -> String {
    if let failure = error as? Failure {
        return failure.description
    }

    let held = error as NSError
    let reason = held.localizedFailureReason.map { ": \($0)" } ?? ""

    return held.localizedDescription + reason
}

@main
struct Reader {
    static func main() async {
        do {
            let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
            try emit(try await answer(arguments))
        } catch {
            FileHandle.standardError.write(Data("xixo-mac-reader: \(said(error))\n".utf8))
            exit(1)
        }
    }
}
