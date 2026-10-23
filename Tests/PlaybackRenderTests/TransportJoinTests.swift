import Foundation
@testable @_spi(Testing) import PlaybackRender
import PlaybackRenderTestSupport
import XCTest

/// A next item whose `open()` stands in for a slow URL resolve: it runs `whileOpening` once (where a
/// test moves the clock or edits the queue), then throws if it was interrupted meanwhile, as a
/// cancelled network open does.
private final class SlowOpenSource: ItemSource, @unchecked Sendable {
    struct Interrupted: Error {}

    let inner: FakeItemSource
    var whileOpening: (() -> Void)?
    private(set) var opens = 0
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var interruptedThrough: UInt64?
    private var _interrupts = 0

    var interrupts: Int { lock.withLock { _interrupts } }

    init(_ inner: FakeItemSource) {
        self.inner = inner
    }

    var frameCount: Int64? { inner.frameCount }

    func begin(epoch: UInt64) {
        lock.withLock { self.epoch = epoch }
    }

    func open() throws -> PCMFormat {
        opens += 1
        if let whileOpening {
            self.whileOpening = nil
            whileOpening()
        }
        let interrupted = lock.withLock { interruptedThrough.map { $0 >= epoch } ?? false }
        if interrupted { throw Interrupted() }
        return try inner.open()
    }

    func seek(toFrame frame: Int64) throws -> Int64 { try inner.seek(toFrame: frame) }
    func nextChunk() throws -> [Float]? { try inner.nextChunk() }

    func interrupt(through epoch: UInt64) {
        lock.withLock {
            _interrupts += 1
            interruptedThrough = max(interruptedThrough ?? 0, epoch)
        }
    }

    func release() { inner.release() }
}

/// The join between two items through the public API, on the fake output's manual clock: when the
/// next item opens, edits to it while it opens, and a delaying processor across it. Eight frames a
/// second; a chunk is a quarter second.
final class TransportJoinTests: XCTestCase {
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

    /// Six seconds, samples 0 to 47: long enough that decode reaches its end mid-playback.
    private lazy var long = FakeItemSource(format: mono, frames: 48, chunkFrames: 2)
    /// Three seconds, samples 0 to 23.
    private lazy var a = FakeItemSource(format: mono, frames: 24, chunkFrames: 2)
    /// Two seconds, samples 1000 to 1015.
    private lazy var b = FakeItemSource(format: mono, frames: 16, chunkFrames: 2, base: 1000)
    private lazy var slowB = SlowOpenSource(b)

    /// `transport.position` after each pump where it moved, as a UI polling it sees, and whether
    /// `.ended` had been sent by then.
    private var samples: [(heard: Heard, afterEnded: Bool)] = []

    private func pump() {
        timer.sync()
        executor.runUntilIdle()
        timer.fire()
        guard let position = transport.position else { return }
        let heard = Heard(item: position.item, frame: Int64(position.seconds * 8))
        if heard != samples.last?.heard { samples.append((heard, statuses.last == .ended)) }
    }

    private func run(for seconds: TimeInterval) {
        for _ in 0..<Int(seconds * 4) {
            output.advance(by: 0.25)
            pump()
        }
    }

    private var heard: [Float] {
        output.played.flatMap { span -> [Float] in
            guard case let .audio(_, _, samples) = span else { return [] }
            return samples
        }
    }

    /// Silence the speaker played between two runs of audio.
    private var gaps: [TimeInterval] {
        let lastAudio = output.played.lastIndex { if case .audio = $0 { true } else { false } } ?? 0
        return output.played.prefix(lastAudio).compactMap {
            if case let .silence(_, duration) = $0 { duration } else { nil }
        }
    }

    private var crossed: [String] {
        recorder.events.compactMap { if case let .crossed(item, _) = $0 { item } else { nil } }
    }

    private var statuses: [TransportStatus] {
        recorder.events.compactMap { if case let .status(status) = $0 { status } else { nil } }
    }

    private var positions: [Heard] { samples.map(\.heard) }

    private var failures: Int {
        recorder.events.filter { if case .failed = $0 { true } else { false } }.count
    }

    // MARK: Opening the next item ahead

    // A resolve inside `open()` runs once decode of the item before has ended, which is the
    // feeder's depth ahead of the speaker, so it overlaps the tail instead of gapping the join.
    func testASlowOpenOfTheNextItemOverlapsTheBufferedTailWithNoGap() {
        var openedAt: TimeInterval?
        slowB.whileOpening = { [output] in
            openedAt = output.currentTime()
            output.advance(by: 1.5)
        }
        transport.setCurrent(item: "a", source: long)
        transport.setNext(item: "b", source: slowB)
        transport.play()
        pump()
        run(for: 8)

        XCTAssertEqual(heard, (0..<48).map(Float.init) + (1000..<1016).map(Float.init))
        XCTAssertEqual(gaps, [])
        XCTAssertLessThanOrEqual(try XCTUnwrap(openedAt), 6 - 1.5, "opened too late to hide a 1.5 s resolve")
        XCTAssertEqual(crossed, ["a", "b"])
        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
    }

    // media3 releases a removed period's loader, which cancels its `DataSource.open`.
    func testANextItemRemovedWhileItOpensIsInterruptedAndNeverPlayed() {
        slowB.whileOpening = { [self] in
            transport.clearNext()
            timer.sync()
        }
        transport.setCurrent(item: "a", source: long)
        transport.setNext(item: "b", source: slowB)
        transport.play()
        pump()
        run(for: 8)

        XCTAssertEqual(slowB.interrupts, 1)
        XCTAssertEqual(heard, (0..<48).map(Float.init))
        XCTAssertEqual(crossed, ["a"])
        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
        XCTAssertEqual(failures, 0)
    }

    func testANextItemReplacedWhileItOpensIsInterruptedAndTheReplacementJoins() {
        let c = FakeItemSource(format: mono, frames: 8, chunkFrames: 2, base: 500)
        slowB.whileOpening = { [self] in
            transport.setNext(item: "c", source: c)
            timer.sync()
        }
        transport.setCurrent(item: "a", source: long)
        transport.setNext(item: "b", source: slowB)
        transport.play()
        pump()
        run(for: 8)

        XCTAssertEqual(slowB.interrupts, 1)
        XCTAssertEqual(heard, (0..<48).map(Float.init) + (500..<508).map(Float.init))
        XCTAssertEqual(gaps, [])
        XCTAssertEqual(crossed, ["a", "c"])
        XCTAssertEqual(failures, 0)
    }

    // The seek replays the window from the new position, so the next item opens again when decode
    // reaches it, from a clean epoch.
    func testASeekInTheCurrentItemWhileTheNextOpensInterruptsThatOpen() {
        slowB.whileOpening = { [self] in
            transport.seek(item: "a", toSeconds: 5)
            timer.sync()
        }
        transport.setCurrent(item: "a", source: long)
        transport.setNext(item: "b", source: slowB)
        transport.play()
        pump()
        run(for: 8)

        XCTAssertEqual(slowB.interrupts, 1)
        XCTAssertEqual(slowB.opens, 2)
        XCTAssertEqual(Array(heard.suffix(24)), (40..<48).map(Float.init) + (1000..<1016).map(Float.init))
        XCTAssertEqual(crossed, ["a", "b"])
        XCTAssertEqual(failures, 0)
    }

    // MARK: A delaying processor across the join

    /// A then b with no processor, every quarter second.
    private let positionsOfAThenB: [Heard] = [
        Heard(item: "a", frame: 0), Heard(item: "a", frame: 2), Heard(item: "a", frame: 4),
        Heard(item: "a", frame: 6), Heard(item: "a", frame: 8), Heard(item: "a", frame: 10),
        Heard(item: "a", frame: 12), Heard(item: "a", frame: 14), Heard(item: "a", frame: 16),
        Heard(item: "a", frame: 18), Heard(item: "a", frame: 20), Heard(item: "a", frame: 22),
        Heard(item: "b", frame: 0), Heard(item: "b", frame: 2), Heard(item: "b", frame: 4),
        Heard(item: "b", frame: 6), Heard(item: "b", frame: 8), Heard(item: "b", frame: 10),
        Heard(item: "b", frame: 12), Heard(item: "b", frame: 14), Heard(item: "b", frame: 16),
    ]

    // Output frames are re-tagged against their input, so a look-ahead limiter's latency is never
    // reported as position: media3 has no latency API either.
    func testALookAheadProcessorShiftsNoPositionAcrossAGaplessJoinAndDrainsBeforeEnded() throws {
        transport.setProcessors([DelayProcessor(frames: 3)])
        transport.setCurrent(item: "a", source: a)
        transport.setNext(item: "b", source: b)
        transport.play()
        pump()
        run(for: 6)

        XCTAssertEqual(heard, (0..<24).map(Float.init) + (1000..<1016).map(Float.init))
        XCTAssertEqual(positions, positionsOfAThenB)
        XCTAssertEqual(crossed, ["a", "b"])
        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
        // The frames held at the end of the last item are heard before it ends: the pump that reaches b's
        // end sends `.ended`, so only the sample read after it, at that end, follows `.ended`.
        XCTAssertEqual(samples.filter(\.afterEnded).map(\.heard), [Heard(item: "b", frame: 16)])
    }

    // A format change drains the chain before the flush that reconfigures it, so a's held tail is
    // heard and b starts at its own frame 0.
    func testALookAheadProcessorDrainsBeforeTheFlushAtAFormatChangeJoin() {
        let stereoB = FakeItemSource(format: PCMFormat(sampleRate: 8, channelCount: 2), frames: 16, chunkFrames: 2, base: 1000)
        transport.setProcessors([DelayProcessor(frames: 3)])
        transport.setCurrent(item: "a", source: a)
        transport.setNext(item: "b", source: stereoB)
        transport.play()
        pump()
        run(for: 6)

        XCTAssertEqual(heard, (0..<24).map(Float.init) + (1000..<1032).map(Float.init))
        XCTAssertEqual(gaps, [])
        XCTAssertEqual(positions, positionsOfAThenB)
        XCTAssertEqual(crossed, ["a", "b"])
        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
    }
}
