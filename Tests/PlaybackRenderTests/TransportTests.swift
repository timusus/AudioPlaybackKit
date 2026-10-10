import Foundation
@testable import PlaybackRender
import XCTest

/// Fires the pump by hand on the transport's queue, after every call already made.
final class ManualPumpTimer: PumpTimer, @unchecked Sendable {
    private var queue: DispatchQueue?
    private var tick: (@Sendable () -> Void)?

    func start(interval: TimeInterval, queue: DispatchQueue, tick: @escaping @Sendable () -> Void) {
        self.queue = queue
        self.tick = tick
    }

    func cancel() {}

    func fire() {
        queue!.sync(execute: tick!)
    }

    /// Waits for every call already made, without pumping.
    func sync() {
        queue!.sync {}
    }
}

/// Supplies `chunks` two-frame chunks, then throws, like a network source that gave up.
private final class FailsMidwaySource: ItemSource, @unchecked Sendable {
    struct Failure: Error {}

    let format: PCMFormat
    private var remaining: Int

    init(format: PCMFormat, chunks: Int) {
        self.format = format
        remaining = chunks
    }

    func begin(epoch: UInt64) {}
    func open() throws -> PCMFormat { format }
    func seek(toFrame frame: Int64) throws -> Int64 { frame }

    func nextChunk() throws -> [Float]? {
        guard remaining > 0 else { throw Failure() }
        remaining -= 1
        return [Float](repeating: -1, count: 2 * format.channelCount)
    }

    func interrupt(through epoch: UInt64) {}
}

final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [TransportEvent<String>] = []

    var events: [TransportEvent<String>] { lock.withLock { _events } }

    func append(_ event: TransportEvent<String>) {
        lock.withLock { _events.append(event) }
    }
}

/// The transport through its public API, on the fake output's manual clock, a hand-fired pump and
/// hand-run decode jobs. Eight frames a second keeps every time exact; a chunk is a quarter second.
final class TransportTests: XCTestCase {
    private struct Heard: Equatable {
        var item: String
        var frame: Int64
    }

    private let mono = PCMFormat(sampleRate: 8, channelCount: 1)
    private let output = FakeAudioOutput()
    private let timer = ManualPumpTimer()
    private let executor = ManualExecutor()
    private let recorder = EventRecorder()
    private lazy var transport = Transport<String>(output: output, timer: timer, executor: executor) { [recorder] in
        recorder.append($0)
    }

    /// Three seconds, samples 0 to 23.
    private lazy var a = FakeItemSource(format: mono, frames: 24, chunkFrames: 2)
    /// Two seconds, samples 1000 to 1015.
    private lazy var b = FakeItemSource(format: mono, frames: 16, chunkFrames: 2, base: 1000)

    /// Runs the calls made, then the decode jobs they queued, then one pump, with the clock still.
    private func pump() {
        timer.sync()
        executor.runUntilIdle()
        timer.fire()
    }

    /// Plays on in quarter-second steps, decoding and pumping after each.
    private func run(for seconds: TimeInterval) {
        for _ in 0..<Int(seconds * 4) {
            output.advance(by: 0.25)
            pump()
        }
    }

    /// Every sample heard, silence skipped.
    private var heard: [Float] {
        output.played.flatMap { span -> [Float] in
            guard case let .audio(_, _, samples) = span else { return [] }
            return samples
        }
    }

    private func ramp(_ range: Range<Int>) -> [Float] {
        range.map(Float.init)
    }

    private var crossed: [String] {
        recorder.events.compactMap { if case let .crossed(item) = $0 { item } else { nil } }
    }

    private var statuses: [TransportStatus] {
        recorder.events.compactMap { if case let .status(status) = $0 { status } else { nil } }
    }

    private var positions: [Heard] {
        recorder.events.compactMap {
            guard case let .position(item, frame, sampleRate) = $0 else { return nil }
            XCTAssertEqual(sampleRate, 8)
            return Heard(item: item, frame: frame)
        }
    }

    private var failedItems: [String?] {
        recorder.events.compactMap { if case let .failed(item, _) = $0 { item } else { nil } }
    }

    func testTwoItemsPlayGaplesslyAndReportTheJoinWhenItIsHeard() {
        transport.setCurrent(item: "a", source: a)
        transport.setNext(item: "b", source: b)
        transport.play()
        pump()
        run(for: 6)

        XCTAssertEqual(heard, ramp(0..<24) + ramp(1000..<1016))
        XCTAssertEqual(crossed, ["a", "b"])
        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
        XCTAssertEqual(
            positions,
            stride(from: 0, through: 22, by: 2).map { Heard(item: "a", frame: $0) }
                + stride(from: 0, through: 16, by: 2).map { Heard(item: "b", frame: $0) }
        )
    }

    func testPauseHoldsThePositionAndPlayResumesWhereItStopped() {
        transport.setCurrent(item: "a", source: a)
        transport.play()
        pump()
        run(for: 1)

        transport.pause()
        timer.sync()
        XCTAssertEqual(output.rate, 0)
        run(for: 1)
        XCTAssertEqual(positions.last, Heard(item: "a", frame: 8))

        transport.play()
        pump()
        run(for: 3)

        XCTAssertEqual(heard, ramp(0..<24))
        XCTAssertEqual(statuses, [.buffering, .playing, .paused, .buffering, .playing, .ended])
    }

    func testRateSpeedsTheOutputClockAndThePositionFollowsIt() {
        transport.setCurrent(item: "a", source: a)
        transport.play()
        pump()
        run(for: 0.5)
        XCTAssertEqual(positions.last, Heard(item: "a", frame: 4))

        transport.setRate(2)
        timer.sync()
        XCTAssertEqual(output.rate, 2)
        run(for: 0.5)
        XCTAssertEqual(positions.last, Heard(item: "a", frame: 12))

        run(for: 1)
        XCTAssertEqual(heard, ramp(0..<24))
        XCTAssertEqual(statuses.last, .ended)
    }

    func testSeekWithinAnItemThenBackAcrossAJoinDecodeHadPassed() {
        transport.setCurrent(item: "a", source: a)
        transport.setNext(item: "b", source: b)
        transport.play()
        pump()
        run(for: 0.5)

        transport.seek(item: "a", toFrame: 16)
        pump()
        run(for: 0.75)
        // B's first frames are already written, so decode is past the join.
        XCTAssertTrue(output.enqueues.contains { $0.samples == [1000, 1001] })

        transport.seek(item: "a", toFrame: 4)
        pump()
        run(for: 6)

        XCTAssertEqual(heard, ramp(0..<4) + ramp(16..<22) + ramp(4..<24) + ramp(1000..<1016))
        XCTAssertEqual(crossed, ["a", "b"])

        // A is behind the item heard, so the sequencer has let it go and the seek does nothing.
        transport.seek(item: "a", toFrame: 0)
        pump()
        run(for: 1)
        XCTAssertEqual(heard, ramp(0..<4) + ramp(16..<22) + ramp(4..<24) + ramp(1000..<1016))
        XCTAssertEqual(statuses.last, .ended)
    }

    func testSetCurrentDropsTheNextItem() {
        transport.setCurrent(item: "a", source: a)
        transport.setNext(item: "b", source: b)
        transport.setCurrent(item: "c", source: FakeItemSource(format: mono, frames: 8, chunkFrames: 2, base: 500))
        transport.play()
        pump()
        run(for: 2)

        XCTAssertEqual(heard, ramp(500..<508))
        XCTAssertEqual(crossed, ["c"])
        XCTAssertEqual(statuses.last, .ended)
    }

    func testSetNextAfterTheEndPlaysOnFromThere() {
        transport.setCurrent(item: "a", source: a)
        transport.play()
        pump()
        run(for: 3.25)
        XCTAssertEqual(statuses.last, .ended)

        transport.setNext(item: "b", source: b)
        pump()
        run(for: 2.25)

        XCTAssertEqual(heard, ramp(0..<24) + ramp(1000..<1016))
        XCTAssertEqual(crossed, ["a", "b"])
        XCTAssertEqual(statuses, [.buffering, .playing, .ended, .buffering, .playing, .ended])
    }

    func testADroppingProcessorSkipsThePositionOverWhatItDropped() {
        transport.setProcessors([DropRangesProcessor([4..<12])])
        transport.setCurrent(item: "a", source: a)
        transport.play()
        pump()
        run(for: 1)

        XCTAssertEqual(positions, [
            Heard(item: "a", frame: 0), Heard(item: "a", frame: 2), Heard(item: "a", frame: 12),
            Heard(item: "a", frame: 14), Heard(item: "a", frame: 16),
        ])

        run(for: 2)
        XCTAssertEqual(heard, ramp(0..<4) + ramp(12..<24))
        XCTAssertEqual(statuses.last, .ended)
    }

    func testAnOutputAutoFlushRefeedsFromTheHeardPosition() {
        transport.setCurrent(item: "a", source: a)
        transport.play()
        pump()
        run(for: 1)

        output.injectAutoFlush()
        pump()
        run(for: 2.25)

        XCTAssertEqual(heard, ramp(0..<24))
        XCTAssertEqual(statuses, [.buffering, .playing, .buffering, .playing, .ended])
    }

    func testASourceFailurePausesAndReportsTheItemUntilANewCurrent() {
        transport.setCurrent(item: "a", source: FailsMidwaySource(format: mono, chunks: 2))
        transport.play()
        pump()

        XCTAssertEqual(failedItems, ["a"])
        XCTAssertEqual(statuses, [.buffering, .paused])
        XCTAssertEqual(output.rate, 0)

        transport.play()
        pump()
        XCTAssertEqual(statuses, [.buffering, .paused])

        transport.setCurrent(item: "b", source: b)
        transport.play()
        pump()
        run(for: 2.25)
        XCTAssertEqual(heard, ramp(1000..<1016))
        // A's two chunks reached the paused playhead before it failed, so it was current.
        XCTAssertEqual(crossed, ["a", "b"])
        XCTAssertEqual(failedItems, ["a"])
    }

    func testCallsFromManyThreadsRunInOrderOnTheTransportsQueue() {
        let output = FakeAudioOutput()
        let playing = expectation(description: "playing")
        playing.assertForOverFulfill = false
        let crossedB = expectation(description: "crossed b")
        let transport = Transport<String>(output: output) { event in
            XCTAssertFalse(Thread.isMainThread)
            switch event {
            case .status(.playing): playing.fulfill()
            case .crossed(item: "b"): crossedB.fulfill()
            default: break
            }
        }
        transport.setCurrent(item: "a", source: FakeItemSource(format: mono, frames: 4, chunkFrames: 2))
        transport.setNext(item: "b", source: FakeItemSource(format: mono, frames: 4, chunkFrames: 2, base: 1000))

        // No play among them, so `playing` can only come from the one after.
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            switch index % 3 {
            case 0: transport.setRate(1 + Double(index % 4) / 4)
            case 1: transport.seek(item: "a", toFrame: Int64(index % 4))
            default: transport.pause()
            }
        }
        transport.setRate(1)
        transport.play()
        wait(for: [playing], timeout: 5)

        output.advance(by: 0.75)
        wait(for: [crossedB], timeout: 5)
    }
}
