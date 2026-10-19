@testable @_spi(Testing) import PlaybackRender
import XCTest

/// The partial flush on the real renderer: it completes, and audio written after it is accepted.
final class SampleBufferAudioOutputPartialFlushTests: XCTestCase {
    private let format = PCMFormat(sampleRate: 48000, channelCount: 1)

    private func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * 48000))
    }

    private func partialFlush(_ output: SampleBufferAudioOutput, from time: TimeInterval) -> Bool? {
        let done = DispatchSemaphore(value: 0)
        let result = ResultBox()
        output.flush(fromTime: time) {
            result.value = $0
            done.signal()
        }
        return done.wait(timeout: .now() + 5) == .success ? result.value : nil
    }

    private final class ResultBox: @unchecked Sendable {
        var value = false
    }

    func testTheCutIsNeverLaterThanAPresentationTimeStampRoundedDownFromIt() {
        for sampleRate in [8000.0, 44100, 48000] {
            // A segment start 0.4 frame past the grid: the stamp rounds to the frame 0.4 before it.
            let cut = 1 + 0.4 / sampleRate
            let stamp = presentationTime(cut, sampleRate: sampleRate).seconds
            XCTAssertLessThan(stamp, cut)
            XCTAssertLessThanOrEqual(partialFlushSourceTime(cut, sampleRate: sampleRate).seconds, stamp, "\(sampleRate)")
        }
    }

    func testAPartialFlushAheadOfTheClockCompletesAndTheCutIsWrittenAgain() throws {
        let output = SampleBufferAudioOutput()
        try output.enqueue(silence(seconds: 1), format: format, at: 0)
        try output.enqueue(silence(seconds: 1), format: format, at: 1)

        XCTAssertEqual(partialFlush(output, from: 1), true)

        XCTAssertNoThrow(try output.enqueue(silence(seconds: 1), format: format, at: 1))
    }

    func testAPartialFlushBehindThePlayingClockStillCompletes() throws {
        let output = SampleBufferAudioOutput()
        try output.enqueue(silence(seconds: 1), format: format, at: 0)
        output.setRate(1, at: 0)
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertNotNil(partialFlush(output, from: 0.1), "the caller falls back on false; it must not wait forever")
    }
}
