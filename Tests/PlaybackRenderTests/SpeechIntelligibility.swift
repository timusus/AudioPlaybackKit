import Accelerate
import AVFoundation

/// STOI (Taal et al., 2011, as pystoi computes it): 10 kHz, 256-sample Hann frames, 15 third-octave
/// bands from 150 Hz, 384 ms segments, a -15 dB clip, frames 40 dB under the loudest dropped. Two
/// deviations: silent frames are dropped from the frame sequence rather than resynthesised, and the
/// reference's frames may step `rate` hops at a time, so a stretch can be scored against its own source
/// through the ideal time map. The best of a few frames' lag either way is taken.
enum SpeechIntelligibility {
    static let sampleRate = 10000.0
    private static let frame = 256, hop = 128, fftSize = 512, bandCount = 15, segment = 30
    private static let clip = Float(1 + pow(10, 15.0 / 20)), dynamicRange: Float = 40

    static func resample(_ samples: [Float], from rate: Double) -> [Float] {
        let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: source, to: target)!
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count))!
        input.frameLength = input.frameCapacity
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(samples.count) * sampleRate / rate) + 4096)!
        var fed = false
        converter.convert(to: output, error: nil) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    /// STOI of `processed` against `reference`, both at `sampleRate`, the reference's frame m read at
    /// m x hop x `rate`.
    static func score(reference: [Float], processed: [Float], rate: Double = 1, maxLag: Int = 8) -> Double {
        let referenceFrames = Int(Double(reference.count - frame) / (Double(hop) * rate)) + 1
        let referenceStarts = (0..<max(referenceFrames, 0)).map { Int((Double($0 * hop) * rate).rounded()) }
            .filter { $0 + frame <= reference.count }
        let processedStarts = Array(stride(from: 0, through: processed.count - frame, by: hop))
        let (x, energies) = bands(reference, at: referenceStarts)
        let (y, _) = bands(processed, at: processedStarts)
        let loudest = energies.max() ?? 0
        let voiced = energies.indices.filter { energies[$0] > loudest - dynamicRange }
        return (-maxLag...maxLag).map { lag in
            let pairs = voiced.filter { $0 + lag >= 0 && $0 + lag < y.count }
            return intermediate(pairs.map { x[$0] }, pairs.map { y[$0 + lag] })
        }.max() ?? 0
    }

    private static func intermediate(_ x: [[Float]], _ y: [[Float]]) -> Double {
        guard x.count >= segment else { return 0 }
        var total = 0.0, count = 0
        for band in 0..<bandCount {
            let cleanBand = x.map { $0[band] }, noisyBand = y.map { $0[band] }
            for end in segment...x.count {
                let clean = Array(cleanBand[end - segment..<end])
                let noisy = Array(noisyBand[end - segment..<end])
                let scaled = vDSP.multiply(norm(clean) / (norm(noisy) + .ulpOfOne), noisy)
                total += Double(correlation(clean, vDSP.minimum(scaled, vDSP.multiply(clip, clean))))
                count += 1
            }
        }
        return total / Double(count)
    }

    private static func norm(_ values: [Float]) -> Float { sqrt(vDSP.sumOfSquares(values)) }

    private static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        let a = vDSP.add(-vDSP.mean(a), a), b = vDSP.add(-vDSP.mean(b), b)
        return vDSP.dot(a, b) / (norm(a) * norm(b) + .ulpOfOne)
    }

    /// Third-octave band magnitudes and the frame's level in dB, per frame start.
    private static func bands(_ samples: [Float], at starts: [Int]) -> ([[Float]], [Float]) {
        let window = (0..<frame).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0 + 1) / Double(frame + 1))) }
        let dft = try! vDSP.DiscreteFourierTransform(count: fftSize, direction: .forward, transformType: .complexComplex, ofType: Float.self)
        let ranges = bandBins()
        let zeros = [Float](repeating: 0, count: fftSize)
        var magnitudes: [[Float]] = [], energies: [Float] = []
        for start in starts {
            let windowed = vDSP.multiply(Array(samples[start..<start + frame]), window)
            energies.append(20 * log10(norm(windowed) + .ulpOfOne))
            let (real, imaginary) = dft.transform(real: windowed + zeros.dropFirst(frame), imaginary: zeros)
            let power = vDSP.add(vDSP.square(real), vDSP.square(imaginary))
            magnitudes.append(ranges.map { sqrt(vDSP.sum(power[$0])) })
        }
        return (magnitudes, energies)
    }

    private static func bandBins() -> [Range<Int>] {
        let frequencies = (0...fftSize / 2).map { Double($0) * sampleRate / Double(fftSize) }
        func nearest(_ frequency: Double) -> Int {
            frequencies.indices.min { abs(frequencies[$0] - frequency) < abs(frequencies[$1] - frequency) }!
        }
        return (0..<bandCount).map { band in
            nearest(150 * pow(2, Double(2 * band - 1) / 6))..<nearest(150 * pow(2, Double(2 * band + 1) / 6))
        }
    }
}
