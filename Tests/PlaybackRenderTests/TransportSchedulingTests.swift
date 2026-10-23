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

    /// A minute.
    private lazy var long = FakeItemSource(format: mono, frames: 480, chunkFrames: 2)

    func testPlayingWithTheOutputFullArmsOnlyTheWrittenEnd() {
        transport.setCurrent(item: "a", source: a)
        transport.play()
        advance(by: 0)

        // Two seconds are queued of three and the output takes no more: nothing is due before the end.
        XCTAssertEqual(try XCTUnwrap(timer.armedDelay), 2, accuracy: 1e-9)
    }

    func testPlayingSteadilyWithNoObserversArmsOnlyTheRefill() {
        output.capacity = 60
        transport.setCurrent(item: "a", source: long)
        transport.play()
        advance(by: 0)
        XCTAssertEqual(statuses.last, .playing)

        // The 30 s cap is written; the next pump is the refill once `resumeDepth` has played.
        XCTAssertEqual(try XCTUnwrap(timer.armedDelay), 0.5, accuracy: 1e-9)
        let armed = timer.armCount
        advance(by: 5)
        XCTAssertEqual(timer.armCount - armed, 10, "one wakeup per refill and none between")
    }

    func testAFrozenClockArmsTheWrittenEndInsteadOfSpinning() {
        transport.setCurrent(item: "a", source: a)
        transport.play()
        advance(by: 0)
        XCTAssertEqual(statuses.last, .playing)
        let armed = timer.armCount

        // A starved renderer's clock stops at rate 1 until its stall event comes.
        timer.advance(by: 5, clock: { _ in }, settle: executor.runUntilIdle)

        // One wakeup each time the written end falls due by the timer, at 2 s and 4 s, not a spin.
        XCTAssertEqual(timer.armCount - armed, 2)
        XCTAssertEqual(try XCTUnwrap(timer.armedDelay), 1, accuracy: 1e-9)
    }

    func testThePositionIsReadFromTheClockWithNoPump() throws {
        transport.setCurrent(item: "a", source: a)
        transport.play()
        advance(by: 0)

        output.advance(by: 0.6)

        let position = try XCTUnwrap(transport.position)
        XCTAssertEqual(position.item, "a")
        XCTAssertEqual(position.seconds, 0.625, accuracy: 1e-9, "the nearest of the 8 Hz frames")
    }

    func testThePositionIsNilWhileASeekIsQueued() {
        transport.setCurrent(item: "a", source: a)
        transport.play()
        advance(by: 1)
        XCTAssertNotNil(transport.position)

        transport.seek(item: "a", toSeconds: 2)

        XCTAssertNil(transport.position)
        advance(by: 0)
        XCTAssertEqual(transport.position?.seconds, 2)
    }

    func testThePositionNeverGoesBackWhenTheLatencyGrows() throws {
        transport.setCurrent(item: "a", source: a)
        transport.play()
        advance(by: 1)
        let before = try XCTUnwrap(transport.position).seconds

        output.outputLatency = 0.5

        XCTAssertEqual(try XCTUnwrap(transport.position).seconds, before)
    }

    func testAPeriodicObserverFiresOnMultiplesOfItsIntervalAndStopsArmingOnceRemoved() {
        output.capacity = 60
        let fired = Recorded<TimeInterval>()
        transport.setCurrent(item: "a", source: long)
        transport.play()
        advance(by: 0)
        let token = transport.addPeriodicObserver(interval: 0.25) { [output] in fired.append(output.currentTime()) }
        timer.sync()

        advance(by: 1)
        XCTAssertEqual(fired.values, [0.25, 0.5, 0.75, 1.0])

        token.cancel()
        timer.sync()
        XCTAssertEqual(try XCTUnwrap(timer.armedDelay), 0.5, accuracy: 1e-9, "the refill alone")
        advance(by: 2)
        XCTAssertEqual(fired.values.count, 4)
    }

    func testAPeriodicObserverIsRemovedWhenItsTokenIsReleased() {
        output.capacity = 60
        let fired = Recorded<TimeInterval>()
        transport.setCurrent(item: "a", source: long)
        transport.play()
        advance(by: 0)
        var token: TimeObserverToken? = transport.addPeriodicObserver(interval: 0.25) { fired.append(0) }
        advance(by: 0.5)
        XCTAssertEqual(fired.values.count, 2)
        _ = token
        token = nil

        advance(by: 2)
        XCTAssertEqual(fired.values.count, 2)
    }

    // The removal is queued behind a call entry that would fire the observer; the entry must not call it.
    func testACancelledObserverIsNotCalledByAnEntryAlreadyQueued() {
        output.capacity = 60
        let periodic = Recorded<TimeInterval>()
        let boundary = Recorded<TimeInterval>()
        transport.setCurrent(item: "a", source: long)
        transport.play()
        advance(by: 0)
        let tokens = [
            transport.addPeriodicObserver(interval: 0.25) { periodic.append(0) },
            transport.addBoundaryObserver(times: [0.25]) { _, time in boundary.append(time) },
        ]
        timer.sync()

        output.advance(by: 0.5)
        transport.clearNext()
        tokens.forEach { $0.cancel() }
        timer.sync()

        XCTAssertEqual(periodic.values, [])
        XCTAssertEqual(boundary.values, [])
    }

    func testAPeriodicObserverDoesNotFireWhilePaused() {
        let fired = Recorded<TimeInterval>()
        transport.setCurrent(item: "a", source: a)
        let token = transport.addPeriodicObserver(interval: 0.25) { fired.append(0) }
        advance(by: 5)

        XCTAssertEqual(fired.values, [])
        XCTAssertNil(timer.armedDelay)
        token.cancel()
    }

    func testABoundaryFiresOnceWhenPlaybackCrossesIt() {
        output.capacity = 60
        let fired = Recorded<TimeInterval>()
        let items = Recorded<String>()
        transport.setCurrent(item: "a", source: long)
        transport.play()
        advance(by: 0)
        let token = transport.addBoundaryObserver(times: [1.25]) { [output] item, time in
            items.append(item)
            fired.append(time)
            fired.append(output.currentTime())
        }
        timer.sync()

        advance(by: 5)

        XCTAssertEqual(items.values, ["a"])
        XCTAssertEqual(fired.values, [1.25, 1.25], "fired at the time, not at a later refill")
        token.cancel()
    }

    // A call entry runs schedule() without a pump, so the heard position it sees can step back with the latency.
    func testABoundaryDoesNotFireTwiceWhenTheHeardPositionStepsBackAcrossIt() {
        output.capacity = 60
        let fired = Recorded<TimeInterval>()
        transport.setCurrent(item: "a", source: long)
        transport.play()
        advance(by: 0)
        let token = transport.addBoundaryObserver(times: [1.25]) { _, time in fired.append(time) }
        advance(by: 1)
        // The clock moves on with no pump, and a call entry hears the boundary crossed.
        output.advance(by: 0.5)
        transport.clearNext()
        timer.sync()
        XCTAssertEqual(fired.values, [1.25])

        output.outputLatency = 1
        transport.clearNext()
        timer.sync()
        advance(by: 2)

        XCTAssertEqual(fired.values, [1.25])
        token.cancel()
    }

    func testASeekLandingPastABoundaryDoesNotFireIt() {
        output.capacity = 60
        let fired = Recorded<TimeInterval>()
        transport.setCurrent(item: "a", source: long)
        transport.play()
        advance(by: 0)
        let token = transport.addBoundaryObserver(times: [1.25]) { _, time in fired.append(time) }
        advance(by: 0.5)

        transport.seek(item: "a", toSeconds: 2)
        advance(by: 1)

        XCTAssertEqual(fired.values, [])
        token.cancel()
    }

    func testTheHeardBoundaryIsDueBeforeTheWrittenEnd() {
        transport.setCurrent(item: "a", source: a)
        transport.setNext(item: "b", source: b)
        transport.play()
        advance(by: 2.9)

        // `b` starts at 3 s, heard from half a frame (1/16 s) before it.
        XCTAssertEqual(try XCTUnwrap(timer.armedDelay), 0.0375, accuracy: 1e-9)
    }

    func testTheEndOfWhatIsWrittenIsDue() {
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

    // The clock crosses the written end inside the pump's fill, which supplies nothing: that pump
    // never judged the crossing, so the next one (nothing else due between) must still hold.
    func testAnUnderrunTheClockCrossesDuringFillIsHeldByTheNextPumpAtOnce() throws {
        transport.setCurrent(item: "a", source: a)
        transport.play()
        timer.sync()
        while !statuses.contains(.playing), executor.runNext() { timer.advance(by: 0, clock: output.advance(by:)) }
        let writtenEnd = try XCTUnwrap(output.enqueues.last).time + 0.25
        output.advance(by: writtenEnd - 0.05 - output.currentTime())

        output.advanceAfterNextRead(by: 0.1)
        timer.fire()
        timer.advance(by: 0, clock: output.advance(by:))

        XCTAssertEqual(statuses.last, .buffering)
        XCTAssertEqual(output.rate, 0)
    }

    func testTheEndOfTheStreamTheClockCrossesDuringFillIsHeldByTheNextPumpAtOnce() {
        output.outputLatency = 0.1
        transport.setCurrent(item: "a", source: a)
        transport.play()
        advance(by: 3.05)
        XCTAssertEqual(statuses.last, .playing)

        output.advanceAfterNextRead(by: 0.1)
        timer.fire()
        timer.advance(by: 0, clock: output.advance(by:))

        XCTAssertEqual(statuses.last, .ended)
        XCTAssertEqual(output.rate, 0, "held at the end, not left running past it")
    }
}

/// What an observer was called with, from the transport queue.
private final class Recorded<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Value] = []

    var values: [Value] { lock.withLock { _values } }

    func append(_ value: Value) {
        lock.withLock { _values.append(value) }
    }
}
