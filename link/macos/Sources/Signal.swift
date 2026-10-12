import Accelerate
import AVFoundation
import Foundation

let silenceFloor = Float(pow(10, -50.0 / 20))
let shortestSilence = 0.5
let mostSilences = 20
let window = 2048

struct Biquad {
    let b0, b1, b2, a1, a2: Double
    var z1 = 0.0
    var z2 = 0.0

    init(_ b: [Double], _ a: [Double]) {
        b0 = b[0]
        b1 = b[1]
        b2 = b[2]
        a1 = a[1]
        a2 = a[2]
    }

    mutating func step(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y

        return y
    }
}

func kWeighting(_ rate: Double) -> [Biquad] {
    var k = tan(Double.pi * 1681.974450955533 / rate)
    var q = 0.7071752369554196
    let vh = pow(10, 3.999843853973347 / 20)
    let vb = pow(vh, 0.4996667741545416)
    var a0 = 1 + k / q + k * k
    let shelf = Biquad([(vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0],
                       [1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0])

    k = tan(Double.pi * 38.13547087602444 / rate)
    q = 0.5003270373238773
    a0 = 1 + k / q + k * k

    return [shelf, Biquad([1, -2, 1], [1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0])]
}

final class Spectrum {
    let setup: FFTSetup
    let log2n = vDSP_Length(11)
    let rate: Double
    var hann = [Float](repeating: 0, count: window)
    var held: [Float] = []
    var centroids: [Double] = []
    var flatnesses: [Double] = []

    init?(rate: Double) {
        self.rate = rate

        guard let made = vDSP_create_fftsetup(vDSP_Length(11), FFTRadix(kFFTRadix2)) else { return nil }

        setup = made
        vDSP_hann_window(&hann, vDSP_Length(window), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    func add(_ sample: Float) {
        held.append(sample)

        if held.count == window {
            measure(held)
            held.removeFirst(window / 2)
        }
    }

    func measure(_ frame: [Float]) {
        var windowed = [Float](repeating: 0, count: window)
        vDSP_vmul(frame, 1, hann, 1, &windowed, 1, vDSP_Length(window))

        var real = [Float](repeating: 0, count: window / 2)
        var imaginary = [Float](repeating: 0, count: window / 2)
        var magnitudes = [Float](repeating: 0, count: window / 2)

        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                guard let r = realPointer.baseAddress, let i = imaginaryPointer.baseAddress else { return }

                var split = DSPSplitComplex(realp: r, imagp: i)

                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress?.withMemoryRebound(to: DSPComplex.self, capacity: window / 2) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(window / 2))
                    }
                }

                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                split.imagp[0] = 0
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(window / 2))
            }
        }

        var total = 0.0
        var weighted = 0.0
        var logs = 0.0
        var counted = 0.0
        let binWidth = rate / Double(window)

        for (bin, magnitude) in magnitudes.enumerated() {
            let value = Double(magnitude) / 2
            total += 1e-9 + value
            weighted += value * Double(bin) * binWidth
            logs += log(1e-9 + value)
            counted += 1
        }

        guard total > 1e-6 else { return }

        centroids.append(weighted / total)
        flatnesses.append(exp(logs / counted) / (total / counted))
    }
}

func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }

    return values.sorted()[values.count / 2]
}

func percentile(_ sorted: [Double], _ share: Double) -> Double {
    sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * share).rounded())))]
}

func loudness(_ power: Double) -> Double {
    -0.691 + 10 * log10(power)
}

func integrated(_ blocks: [Double]) -> Double? {
    let loud = blocks.filter { $0 > 0 && loudness($0) > -70 }

    guard !loud.isEmpty else { return nil }

    let gate = loudness(loud.reduce(0, +) / Double(loud.count)) - 10
    let kept = loud.filter { loudness($0) > gate }

    guard !kept.isEmpty else { return nil }

    return loudness(kept.reduce(0, +) / Double(kept.count))
}

func loudnessRange(_ blocks: [Double]) -> Double? {
    let loud = blocks.filter { $0 > 0 && loudness($0) > -70 }

    guard !loud.isEmpty else { return nil }

    let gate = loudness(loud.reduce(0, +) / Double(loud.count)) - 20
    let kept = loud.map(loudness).filter { $0 > gate }.sorted()

    guard kept.count > 1 else { return 0 }

    return percentile(kept, 0.95) - percentile(kept, 0.10)
}

func windows(_ steps: [Double], span: Int) -> [Double] {
    guard steps.count >= span else { return steps.isEmpty ? [] : [steps.reduce(0, +) / Double(steps.count)] }

    var held: [Double] = []
    var sum = steps.prefix(span).reduce(0, +)
    held.append(sum / Double(span))

    for at in span..<steps.count {
        sum += steps[at] - steps[at - span]
        held.append(sum / Double(span))
    }

    return held
}

func signal(_ arguments: Arguments) async throws -> Any {
    let seconds = Double(try arguments.int("seconds", 3600))
    let held = asset(arguments)
    let tracks = try await held.loadTracks(withMediaType: .audio)
    var channels = 1
    var signalRate = 0.0

    for track in tracks {
        for description in try await track.load(.formatDescriptions) {
            if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                channels = max(channels, min(2, Int(basic.mChannelsPerFrame)))
                signalRate = max(signalRate, basic.mSampleRate)
            }
        }
    }

    if !(8000...192_000).contains(signalRate) {
        signalRate = 48000
    }

    guard let spectrum = Spectrum(rate: signalRate) else { throw Failure("could not set up the spectrum") }

    var filters = (0..<channels).map { _ in kWeighting(signalRate) }
    let stepFrames = Int(signalRate / 10)
    var steps: [Double] = []
    var stepEnergy = 0.0
    var stepCount = 0
    var peak: Float = 0
    var frame = 0
    var quietFrom: Int? = 0
    var silences: [[Double]] = []
    var silent = 0.0
    let shortest = Int(shortestSilence * signalRate)

    let closeSilence = { (end: Int) in
        guard let from = quietFrom, end - from >= shortest else { return }

        let pair = [(Double(from) / signalRate * 100).rounded() / 100, (Double(end) / signalRate * 100).rounded() / 100]
        silent += pair[1] - pair[0]

        if silences.count < mostSilences {
            silences.append(pair)
        }
    }

    try await samples(held, rate: signalRate, channels: channels, seconds: seconds) { chunk in
        var at = 0

        while at + channels <= chunk.count {
            var energy = 0.0
            var loudest: Float = 0
            var mixed: Float = 0

            for channel in 0..<channels {
                let sample = chunk[at + channel].isFinite ? chunk[at + channel] : 0
                var filtered = Double(sample)

                for stage in 0..<filters[channel].count {
                    filtered = filters[channel][stage].step(filtered)
                }

                energy += filtered * filtered
                loudest = max(loudest, abs(sample))
                mixed += sample / Float(channels)
            }

            peak = max(peak, loudest)
            spectrum.add(mixed)

            if loudest < silenceFloor {
                if quietFrom == nil {
                    quietFrom = frame
                }
            } else {
                closeSilence(frame)
                quietFrom = nil
            }

            stepEnergy += energy
            stepCount += 1

            if stepCount == stepFrames {
                steps.append(stepEnergy / Double(stepFrames))
                stepEnergy = 0
                stepCount = 0
            }

            frame += 1
            at += channels
        }
    }

    closeSilence(frame)

    var answer: [String: Any] = [
        "heard": Double(frame) / signalRate,
        "silences": silences,
        "silent": (silent * 100).rounded() / 100,
    ]

    if let value = integrated(windows(steps, span: 4)) {
        answer["loudness"] = value
    }

    if let value = loudnessRange(windows(steps, span: 30)) {
        answer["range"] = value
    }

    if peak > 0 {
        answer["peak"] = 20 * log10(Double(peak))
    }

    if let value = median(spectrum.centroids) {
        answer["centroid"] = value
    }

    if let value = median(spectrum.flatnesses) {
        answer["flatness"] = value
    }

    return answer
}
