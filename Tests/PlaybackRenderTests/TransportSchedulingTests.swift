import Foundation
@testable @_spi(Testing) import PlaybackRender
import PlaybackRenderTestSupport
import XCTest

/// When the transport asks to be pumped (ADR-0018): only for work due on the clock, never while it
/// has none. Time moves only through `advance`, which pumps as the real timer does, on a wake or an
/// armed deadline, so a wakeup the transport misses leaves it stuck here too.
final class TransportSchedulingTests: XCTestCase {
    private let mono = PCMFormat(sampleRate: 8, channelCount: 1)
    private let output = FakeAudioOutput()
    private let timer = ManualPumpTimer()
    private let executor = ManualExecutor()
    private let recorder = EventRecorder()
    private lazy var transport = Transport<String>(output: output, timer: timer, executor: executor,
                                                   stretch: FakeStretchUnit.stretch()) { [recorder] in
        recorder.append($0)
    }

    /// Three seconds.
    private lazy var a = FakeItemSource(format: mono, frames: 24, chunkFrames: 2)
    /// Two seconds.
    private lazy var b = FakeItemSource(format: mono, frames: 16, chunkFrames: 2, base: 1000)

    /// Decode keeps up: every job a pump queues lands before the next.
    private func advance(by seconds: TimeInterval) {
        timer.advance(by: seconds, clock: output.advance(by:), settle: executor.runUntilIdle)
    }

    private var crossed: [String] {
        recorder.events.compactMap { if case let .crossed(item, _) = $0 { item } else { nil } }
    }

    private var statuses: [TransportStatus] {
        recorder.events.compactMap { if case let .status(status) = $0 { status } else { nil } }
    }

    func testPausedForAMinuteArmsNothing() {
        transport.setCurrent(item: "a", source: a)
        advance(by: 60)

        XCTAssertEqual(statuses, [.buffering, .paused])
        XCTAssertEqual(timer.armCount, 0)
        XCTAssertNil(timer.armedDelay)
    }

    func testIdleWithNoItemArmsNothing() {
        transport.play()
        advance(by: 60)

        XCTAssertEqual(timer.armCount, 0)
        XCTAssertNil(timer.armedDelay)
    }

    func testEndedArmsNothing() {
        transport.setCurrent(item: "a", source: a)
        transport.play()
        advance(by: 60)

        XCTAssertEqual(statuses.last, .ended)
        XCTAssertGreaterThan(timer.armCount, 0)
        XCTAssertNil(timer.armedDelay)
    }

    func testANextItemSetAfterTheEndPlaysOn() {
        transport.setCurrent(item: "a", source: a)
        transport.play()
        advance(by: 60)
        XCTAssertEqual(statuses.last, .ended)

        transport.setNext(item: "b", source: b)
        advance(by: 5)

        XCTAssertEqual(crossed, ["a", "b"])
        XCTAssertEqual(statuses.suffix(2), [.playing, .ended])
    }

    func testPausingDisarms() {
        transport.setCurrent(item: "a", source: a)
        transport.play()
        advance(by: 0)
        XCTAssertNotNil(timer.armedDelay)

        transport.pause()
        timer.sync()
        XCTAssertNil(timer.armedDelay)
    }

    func testPlayingWithTheOutputFullArmsOnlyThePositionCadence() {
        transport.setCurrent(item: "a", source: a)
        transport.play()
        advance(by: 0)

        // Two seconds are queued of three, the output takes no more, and the end is 2 s off.
        XCTAssertEqual(try XCTUnwrap(timer.armedDelay), 0.1, accuracy: 1e-9)
    }

    func testTheHeardBoundaryIsDueBeforeTheNextPositionReport() {
        transport.setCurrent(item: "a", source: a)
        transport.setNext(item: "b", source: b)
        transport.play()
        advance(by: 2.9)

        // `b` starts at 3 s, heard from half a frame (1/16 s) before it.
        XCTAssertEqual(try XCTUnwrap(timer.armedDelay), 0.0375, accuracy: 1e-9)
    }

    func testTheEndOfWhatIsWrittenIsDueBeforeTheNextPositionReport() {
        transport.setCurrent(item: "a", source: a)
        transport.play()
        advance(by: 2.95)

        XCTAssertEqual(try XCTUnwrap(timer.armedDelay), 0.05, accuracy: 1e-9)
    }

    func testTheGaplessCrossingIsReportedWhereTheMapSaysItIsHeard() {
        transport.setCurrent(item: "a", source: a)
        transport.setNext(item: "b", source: b)
        transport.play()
        advance(by: 0)
        while crossed.count < 2, let delay = timer.armedDelay { advance(by: delay) }

        XCTAssertEqual(crossed, ["a", "b"])
        XCTAssertEqual(output.currentTime(), 2.9375, accuracy: 1e-6)
        advance(by: 10)
        XCTAssertEqual(statuses.last, .ended)
    }

    func testAnUnderrunIsDetectedAtTheWrittenEndWithNoPollingInBetween() throws {
        transport.setCurrent(item: "a", source: a)
        transport.play()
        timer.sync()
        // Decode delivers just enough to start and then no more, so the output runs dry.
        while !statuses.contains(.playing), executor.runNext() { timer.advance(by: 0, clock: output.advance(by:)) }
        XCTAssertEqual(statuses, [.buffering, .playing], "started on what was written")
        let writtenEnd = try XCTUnwrap(output.enqueues.last).time + 0.25
        XCTAssertLessThan(writtenEnd, 3)

        timer.advance(by: 1, clock: output.advance(by:))

        XCTAssertEqual(statuses.last, .buffering, "the written end was reached")
        XCTAssertEqual(output.rate, 0)
        XCTAssertNil(timer.armedDelay, "waiting on decode is woken by it, not by the clock")
    }
}
