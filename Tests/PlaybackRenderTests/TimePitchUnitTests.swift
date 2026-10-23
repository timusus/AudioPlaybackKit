@testable import PlaybackRender
import XCTest

final class TimePitchUnitTests: XCTestCase {
    static func fixture(seconds: Int) -> [Float] {
        var state: UInt32 = 12345
        return (0..<(48000 * seconds)).flatMap { frame -> [Float] in
            state = state &* 1664525 &+ 1013904223
            let noise = Float(state >> 16) / 65536 - 0.5
            let time = Float(frame) / 48000
            return [0.4 * sinf(2 * .pi * 440 * time) + 0.05 * noise, 0.3 * sinf(2 * .pi * 660 * time) - 0.05 * noise]
        }
    }

    /// Feeds 4800-frame chunks and renders what each leaves, as `TimeStretch` does.
    static func stretch(_ samples: [Float], rate: Double) -> [Float] {
        let unit = TimePitchUnit(format: PCMFormat(sampleRate: 48000, channelCount: 2))
        unit.rate = rate
        var output: [Float] = []
        for start in stride(from: 0, to: samples.count, by: 9600) {
            unit.append(Array(samples[start..<min(start + 9600, samples.count)]))
            output += unit.render(Int((Double(unit.queuedFrames) - 1) / rate))
        }
        return output
    }

    func testStretchedOutputIsBitIdentical() {
        let output = Self.stretch(Self.fixture(seconds: 5), rate: 1.5)
        var hash: UInt64 = 0xcbf29ce484222325
        for sample in output { hash = (hash ^ UInt64(sample.bitPattern)) &* 0x100000001b3 }
        XCTAssertEqual(output.count, 319_996)
        XCTAssertEqual(hash, 8780940136011198212)
    }
}
