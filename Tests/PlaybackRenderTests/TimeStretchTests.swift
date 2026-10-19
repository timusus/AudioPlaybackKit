@testable import PlaybackRender
import XCTest

/// Speed through `TimeStretch` as the feeder drives it: 4410-frame chunks of one second at 44.1 kHz.
final class TimeStretchTests: XCTestCase {
    private let mono = PCMFormat(sampleRate: 44100, channelCount: 1)
    private let tone = TimeStretchTests.sine([440])

    private static func sine(_ frequencies: [Float], frames: Int = 44100) -> [Float] {
        (0..<frames).map { frame in
            frequencies.reduce(0) { $0 + 0.25 * sinf(Float(frame) * 2 * .pi * $1 / 44100) }
        }
    }

    private func chunks(_ samples: [Float], format: PCMFormat, from start: Int64 = 0) -> [TaggedChunk] {
        let block = 4410 * format.channelCount
        return stride(from: 0, to: samples.count, by: block).map { offset in
            let slice = Array(samples[offset..<min(offset + block, samples.count)])
            let tag = SegmentTag(item: 1, mediaStartFrame: start + Int64(offset / format.channelCount),
                                 frameCount: Int64(slice.count / format.channelCount))
            return TaggedChunk(samples: slice, format: format, tags: [tag])
        }
    }

    private func run(_ samples: [Float], rate: Double, format: PCMFormat? = nil) -> [TimeStretch.Chunk] {
        var stretch = TimeStretch()
        let format = format ?? mono
        return chunks(samples, format: format).flatMap { stretch.process($0, rate: rate) } + stretch.finish()
    }

    /// Upward zero crossings a second in the middle of `samples`, away from the edges.
    private func frequency(_ samples: [Float]) -> Double {
        let middle = samples[(samples.count / 10)..<(samples.count * 9 / 10)]
        let crossings = zip(middle, middle.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        return Double(crossings) / (Double(middle.count) / 44100)
    }

    func testEachRateShortensOrLengthensByTheRateAndKeepsThePitch() {
        for (rate, expected) in [(0.8, 55125.0), (1.5, 29400), (2, 22050), (3, 14700)] {
            let output = run(tone, rate: rate).flatMap(\.samples)
            XCTAssertEqual(Double(output.count), expected, accuracy: expected / 200, "rate \(rate)")
            XCTAssertEqual(frequency(output), 440, accuracy: 5, "rate \(rate)")
        }
    }

    /// The unit lags by about 93 ms at 1x and reports none; uncut, a tone heard from 0.5 s at 1.5x
    /// would start 80 ms late and its last 80 ms would never come out.
    func testTheOutputLinesUpWithTheMedia() {
        let burst = tone.indices.map { $0 >= 11025 && $0 < 33075 ? tone[$0] : 0 } + [Float](repeating: 0, count: 11025)
        for (rate, start, end) in [(1.5, 7350, 22050), (3, 3675, 11025)] {
            let output = run(burst, rate: rate).flatMap(\.samples)
            let loud = output.indices.filter { abs(output[$0]) > 0.125 }
            XCTAssertEqual(Double(loud.first!), Double(start), accuracy: 300, "rate \(rate)")
            XCTAssertEqual(Double(loud.last!), Double(end), accuracy: 300, "rate \(rate)")
        }
    }

    /// A chord's common period (55 Hz here) is below what a pitch-period stretch like Sonic can find,
    /// which smeared it into noise about 4 dB under the notes at 1.5x and above.
    func testAChordStaysAChordAtThreeTimes() {
        let notes: [Float] = [220, 275, 330]
        let output = run(Self.sine(notes, frames: 132_300), rate: 3).flatMap(\.samples)
        let middle = Array(output[11025..<33075])
        var residual = middle
        for note in notes {
            let omega = 2 * Float.pi * note / 44100
            var sine: Float = 0, cosine: Float = 0
            for (index, sample) in middle.enumerated() {
                sine += sample * sinf(omega * Float(index))
                cosine += sample * cosf(omega * Float(index))
            }
            for index in residual.indices {
                residual[index] -= 2 / Float(middle.count) * (sine * sinf(omega * Float(index)) + cosine * cosf(omega * Float(index)))
            }
        }
        let energy = middle.reduce(0) { $0 + $1 * $1 }, noise = residual.reduce(0) { $0 + $1 * $1 }
        XCTAssertGreaterThan(10 * log10(energy / noise), 25)
    }

    func testTheSpansCoverEveryMediaFrameOnceAndSumToTheOutput() {
        let output = run(tone, rate: 1.5)
        let spans = output.flatMap(\.spans)
        XCTAssertEqual(spans.reduce(0) { $0 + $1.outputFrames }, output.reduce(0) { $0 + $1.frameCount })
        XCTAssertEqual(spans.reduce(0) { $0 + $1.tag.frameCount }, 44100)
        for (span, next) in zip(spans, spans.dropFirst()) {
            XCTAssertEqual(next.tag.mediaStartFrame, span.tag.mediaStartFrame + span.tag.frameCount)
        }
    }

    func testStereoChannelsStayInStep() {
        let stereo = tone.flatMap { [$0, -$0] }
        let output = run(stereo, rate: 1.5, format: PCMFormat(sampleRate: 44100, channelCount: 2)).flatMap(\.samples)
        XCTAssertEqual(Double(output.count / 2), 29400, accuracy: 147)
        let error = stride(from: 0, to: output.count, by: 2).map { abs(output[$0] + output[$0 + 1]) }.max()!
        XCTAssertLessThan(error, 0.001)
    }

    func testAtRateOneChunksPassThroughUntouched() {
        var stretch = TimeStretch()
        let chunk = chunks(tone, format: mono)[3]
        let output = stretch.process(chunk, rate: 1)
        XCTAssertEqual(output.map(\.samples), [chunk.samples])
        XCTAssertEqual(output.flatMap(\.spans), [TimeStretch.Span(tag: chunk.tags[0], format: mono, outputFrames: 4410)])
    }

    func testReturningToRateOneFlushesTheStretchThenPassesThrough() {
        var stretch = TimeStretch()
        let input = chunks(tone, format: mono)
        let fast = stretch.process(input[0], rate: 1.5)
        let output = stretch.process(input[1], rate: 1)
        XCTAssertEqual(output.last?.samples, input[1].samples)
        let stretched = (fast + output.dropLast()).flatMap(\.spans)
        XCTAssertEqual(stretched.reduce(0) { $0 + $1.tag.frameCount }, 4410)
        XCTAssertEqual(Double(stretched.reduce(0) { $0 + $1.outputFrames }), 2940, accuracy: 1)
        XCTAssertEqual(stretch.finish().count, 0)
    }
}
