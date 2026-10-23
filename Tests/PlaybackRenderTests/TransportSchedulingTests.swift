import Foundation
@testable @_spi(Testing) import PlaybackRender
import PlaybackRenderTestSupport
import XCTest

/// When the transport asks to be pumped (ADR-0018): only for work due on the clock, never while it
/// has none. The fake timer records what was armed; a test fires the pump itself.
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

    private func pump() {
        timer.sync()
        executor.runUntilIdle()
        timer.fire()
    }

    private var crossed: [String] {
        recorder.events.compactMap { if case let .crossed(item, _) = $0 { item } else { nil } }
    }

    private var statuses: [TransportStatus] {
        recorder.events.compactMap { if case let .status(status) = $0 { status } else { nil } }
    }

    /// Plays on as a timer would: the clock moves to each armed time and the pump runs, until nothing is armed.
    private func runOnTheTimer(limit: TimeInterval) {
        while let delay = timer.armedDelay, output.currentTime() < limit {
            output.advance(by: delay)
            pump()
        }
    }

    /// Plays to `time` in half-second steps so the output never runs dry on the way.
    private func play(to time: TimeInterval) {
        while output.currentTime() + 0.5 < time {
            output.advance(by: 0.5)
            pump()
        }
        output.advance(by: time - output.currentTime())
        pump()
    }

    func testPausedForAMinuteArmsNothing() {
        transport.setCurrent(item: "a", source: a)
        pump()
        output.advance(by: 60)
        pump()

        XCTAssertEqual(statuses, [.buffering, .paused])
        XCTAssertEqual(timer.armCount, 0)
        XCTAssertNil(timer.armedDelay)
    }

    func testIdleWithNoItemArmsNothing() {
        transport.play()
        pump()
        output.advance(by: 60)
        pump()

        XCTAssertEqual(timer.armCount, 0)
        XCTAssertNil(timer.armedDelay)
    }

    func testEndedArmsNothing() {
        transport.setCurrent(item: "a", source: a)
        transport.play()
        pump()
        runOnTheTimer(limit: 60)

        XCTAssertEqual(statuses.last, .ended)
        XCTAssertGreaterThan(timer.armCount, 0)
        XCTAssertNil(timer.armedDelay)
    }

    func testPausingDisarms() {
        transport.setCurrent(item: "a", source: a)
        transport.play()
        pump()
        XCTAssertNotNil(timer.armedDelay)

        transport.pause()
        timer.sync()
        XCTAssertNil(timer.armedDelay)
    }

    func testPlayingWithTheOutputFullArmsOnlyThePositionCadence() {
        transport.setCurrent(item: "a", source: a)
        transport.play()
        pump()

        // Two seconds are queued of three, the output takes no more, and the end is 2 s off.
        XCTAssertEqual(try XCTUnwrap(timer.armedDelay), 0.1, accuracy: 1e-9)
    }

    func testTheHeardBoundaryIsDueBeforeTheNextPositionReport() {
        transport.setCurrent(item: "a", source: a)
        transport.setNext(item: "b", source: b)
        transport.play()
        pump()
        play(to: 2.9)

        // `b` starts at 3 s, heard from half a frame (1/16 s) before it.
        XCTAssertEqual(try XCTUnwrap(timer.armedDelay), 0.0375, accuracy: 1e-9)
    }

    func testTheEndOfWhatIsWrittenIsDueBeforeTheNextPositionReport() {
        transport.setCurrent(item: "a", source: a)
        transport.play()
        pump()
        play(to: 2.95)

        XCTAssertEqual(try XCTUnwrap(timer.armedDelay), 0.05, accuracy: 1e-9)
    }

    func testTheGaplessCrossingIsReportedWhereTheMapSaysItIsHeard() {
        transport.setCurrent(item: "a", source: a)
        transport.setNext(item: "b", source: b)
        transport.play()
        pump()
        var crossedAt: TimeInterval?
        while let delay = timer.armedDelay, output.currentTime() < 10 {
            output.advance(by: delay)
            pump()
            if crossedAt == nil, crossed.count == 2 { crossedAt = output.currentTime() }
        }

        XCTAssertEqual(crossed, ["a", "b"])
        XCTAssertEqual(try XCTUnwrap(crossedAt), 2.9375, accuracy: 1e-6)
        XCTAssertEqual(statuses.last, .ended)
    }

    func testAnUnderrunIsDetectedAtTheWrittenEndWithNoPollingInBetween() throws {
        transport.setCurrent(item: "a", source: a)
        transport.play()
        timer.sync()
        // Decode delivers just enough to start and then no more, so the output runs dry.
        while !statuses.contains(.playing), executor.runNext() { timer.fire() }
        XCTAssertEqual(statuses, [.buffering, .playing], "started on what was written")
        let writtenEnd = try XCTUnwrap(output.enqueues.last).time + 0.25
        XCTAssertLessThan(writtenEnd, 3)

        while let delay = timer.armedDelay, output.currentTime() < writtenEnd {
            output.advance(by: min(delay, writtenEnd - output.currentTime()))
            timer.fire()
        }

        XCTAssertEqual(statuses.last, .buffering, "the written end was reached")
        XCTAssertEqual(output.rate, 0)
        XCTAssertNil(timer.armedDelay, "waiting on decode is woken by it, not by the clock")
    }
}
