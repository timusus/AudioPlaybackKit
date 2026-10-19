@testable import PlaybackRender
import XCTest

/// The time-stretch keeps pitch and hits the requested length; one second of a 440 Hz tone at 44.1 kHz.
final class SonicTests: XCTestCase {
    private let tone: [Float] = (0..<44100).map { 0.5 * sinf(Float($0) * 2 * .pi * 440 / 44100) }

    private func stretch(_ input: [Float], speed: Double, channels: Int = 1, block: Int = 4410) -> [Float] {
        var sonic = Sonic(sampleRate: 44100, channels: channels, speed: speed)
        var output: [Float] = []
        for start in stride(from: 0, to: input.count, by: block * channels) {
            output += sonic.process(Array(input[start..<min(start + block * channels, input.count)]))
        }
        return output + sonic.finish()
    }

    /// Upward zero crossings a second in the middle of `samples`, away from the edges.
    private func frequency(_ samples: [Float]) -> Double {
        let middle = samples[(samples.count / 10)..<(samples.count * 9 / 10)]
        let crossings = zip(middle, middle.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        return Double(crossings) / (Double(middle.count) / 44100)
    }

    func testSpeedingUpShortensByTheRateAndKeepsThePitch() {
        let output = stretch(tone, speed: 1.5)
        XCTAssertEqual(Double(output.count), 29400, accuracy: 294)
        XCTAssertEqual(frequency(output), 440, accuracy: 5)
    }

    func testSlowingDownLengthensByTheRateAndKeepsThePitch() {
        let output = stretch(tone, speed: 0.8)
        XCTAssertEqual(Double(output.count), 55125, accuracy: 551)
        XCTAssertEqual(frequency(output), 440, accuracy: 5)
    }

    // Within 3%: out here Sonic adds or drops a fraction of a period per period, rounded down.
    func testBeyondTwiceAndUnderHalfTheLengthStillFollowsTheRate() {
        XCTAssertEqual(Double(stretch(tone, speed: 3).count), 14700, accuracy: 441)
        XCTAssertEqual(Double(stretch(tone, speed: 0.25).count), 176400, accuracy: 5292)
    }

    func testStereoChannelsStayInterleavedAndInStep() {
        let stereo = tone.flatMap { [$0, -$0] }
        let output = stretch(stereo, speed: 1.5, channels: 2)
        XCTAssertEqual(Double(output.count / 2), 29400, accuracy: 294)
        XCTAssertEqual(output.count % 2, 0)
        for frame in stride(from: 0, to: output.count, by: 2) where output[frame] != -output[frame + 1] {
            return XCTFail("frame \(frame / 2) is not mirrored")
        }
    }

    func testTheFirstOutputSampleIsTheFirstInputSample() {
        XCTAssertEqual(stretch(tone, speed: 1.5).first, tone[0])
        XCTAssertEqual(stretch(Array(tone[1000...]), speed: 0.8).first, tone[1000])
    }

    func testAtSpeedOneEverythingBufferedComesOutUntouched() {
        var sonic = Sonic(sampleRate: 44100, channels: 1, speed: 1.5)
        let fast = sonic.process(Array(tone[..<4410]))
        let buffered = sonic.bufferedFrames
        XCTAssertGreaterThan(buffered, 0)

        sonic.speed = 1
        let rest = sonic.process(Array(tone[4410..<8820]))

        XCTAssertEqual(Array(rest.suffix(4410)), Array(tone[4410..<8820]), "the new input is copied as is")
        XCTAssertEqual(rest.count, buffered + 4410)
        XCTAssertEqual(sonic.bufferedFrames, 0)
        XCTAssertFalse(fast.isEmpty)
    }
}
