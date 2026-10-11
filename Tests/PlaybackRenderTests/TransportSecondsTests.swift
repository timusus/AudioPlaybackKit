import Foundation
import PlaybackRender
import PlaybackRenderTestSupport
import XCTest

/// Seconds at the transport's boundary, through its public API on the fake output and manual clock.
final class TransportSecondsTests: XCTestCase {
    private final class Rig {
        let output = FakeAudioOutput()
        let timer = ManualPumpTimer()
        let executor = ManualExecutor()
        let recorder = EventRecorder()
        lazy var transport = Transport<String>(output: output, timer: timer, executor: executor) { [recorder] in
            recorder.append($0)
        }

        func pump() {
            timer.sync()
            executor.runUntilIdle()
            timer.fire()
        }

        var positions: [(item: String, seconds: TimeInterval, duration: TimeInterval?)] {
            recorder.events.compactMap {
                guard case let .position(item, seconds, duration) = $0 else { return nil }
                return (item, seconds, duration)
            }
        }

        /// The first sample written after the first `skipping` writes: the frame decode landed on.
        func firstSampleWritten(skipping: Int = 0) -> Float? {
            output.enqueues.dropFirst(skipping).first?.samples.first
        }
    }

    private func source(rate: Double, frames: Int64, base: Float = 0) -> FakeItemSource {
        FakeItemSource(format: PCMFormat(sampleRate: rate, channelCount: 1), frames: frames, chunkFrames: 441, base: base)
    }

    // 0.0001 s is 4.41 frames at 44.1 kHz and 4.8 at 48 kHz: the nearest frame, not the one before.
    func testAStartInSecondsLandsOnTheNearestFrameAndIsReportedInSeconds() {
        for (rate, frame) in [(44100.0, Float(4)), (48000.0, Float(5))] {
            let rig = Rig()
            rig.transport.setCurrent(item: "a", source: source(rate: rate, frames: Int64(rate) * 2), startSeconds: 0.0001)
            rig.pump()

            XCTAssertEqual(rig.firstSampleWritten(), frame, "\(rate)")
            XCTAssertEqual(rig.positions.map(\.seconds), [Double(frame) / rate], "\(rate)")
            XCTAssertEqual(rig.positions.map(\.duration), [2], "\(rate)")
        }
    }

    // A reported position fed back as a seek lands on the frame it was reported for.
    func testAReportedPositionSeeksBackToTheSameFrame() throws {
        for rate in [44100.0, 48000.0] {
            let rig = Rig()
            rig.transport.setCurrent(item: "a", source: source(rate: rate, frames: Int64(rate) * 2), startSeconds: 12345 / rate)
            rig.pump()
            XCTAssertEqual(rig.firstSampleWritten(), 12345, "\(rate)")
            let reported = try XCTUnwrap(rig.positions.last?.seconds)

            rig.transport.seek(item: "a", toSeconds: 1)
            rig.pump()
            let written = rig.output.enqueues.count
            rig.transport.seek(item: "a", toSeconds: reported)
            rig.pump()
            XCTAssertEqual(rig.firstSampleWritten(skipping: written), 12345, "\(rate)")
            XCTAssertEqual(rig.positions.map(\.seconds), [reported, 1, reported], "\(rate)")
        }
    }

    // Both calls run before the decode job that opens the source.
    func testASeekBeforeTheSourceHasOpenedConvertsAtItsRate() {
        let rig = Rig()
        rig.transport.setCurrent(item: "a", source: source(rate: 44100, frames: 88200))
        rig.transport.seek(item: "a", toSeconds: 1.5)
        rig.pump()

        XCTAssertEqual(rig.firstSampleWritten(), 66150)
        XCTAssertEqual(rig.positions.map(\.seconds), [1.5])
    }

    func testASeekToANextItemBeforeItsSourceHasOpenedConvertsAtItsRate() {
        let rig = Rig()
        rig.transport.setCurrent(item: "a", source: source(rate: 44100, frames: 88200))
        rig.transport.setNext(item: "b", source: source(rate: 48000, frames: 96000, base: 1_000_000))
        rig.transport.seek(item: "b", toSeconds: 0.5)
        rig.pump()

        XCTAssertEqual(rig.firstSampleWritten(), 1_024_000)
        XCTAssertEqual(rig.positions.map(\.item), ["b"])
        XCTAssertEqual(rig.positions.map(\.seconds), [0.5])
        XCTAssertEqual(rig.positions.map(\.duration), [2])
    }

    // A caller tells a position from before its seek from the seek's first audio by the `.sought`
    // between them, even for the same item and with the old position sent after the call was made.
    func testEverySetCurrentAndSeekIsAnsweredInCallOrderBeforeItsAudio() {
        let rig = Rig()
        rig.transport.setCurrent(item: "a", source: source(rate: 8, frames: 80))
        rig.transport.setNext(item: "b", source: source(rate: 8, frames: 80))
        rig.transport.play()
        rig.pump()
        rig.output.advance(by: 1)
        rig.pump()
        rig.transport.seek(item: "a", toSeconds: 5)
        rig.pump()
        rig.transport.seek(item: "b", toSeconds: 2)
        rig.pump()
        rig.transport.seek(item: "a", toSeconds: 1)
        rig.pump()

        let events = rig.recorder.events.compactMap { event -> String? in
            switch event {
            case let .sought(item, seconds): "sought \(item) \(seconds)"
            case let .position(item, seconds, _): "position \(item) \(seconds)"
            case .crossed, .status, .failed: nil
            }
        }
        XCTAssertEqual(events, [
            "sought a 0.0", "position a 0.0", "position a 1.0",
            "sought a 5.0", "position a 5.0",
            "sought b 2.0", "position b 2.0",
            "sought a 1.0",
        ], "a seek to an item passed is ignored but still answered")
    }
}
