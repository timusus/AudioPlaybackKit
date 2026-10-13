import Foundation
@_spi(Testing) import PlaybackRender
import PlaybackRenderTestSupport
import XCTest

/// Supplies `chunks` two-frame chunks of samples `base` up, then throws, like a network source that gave up.
private final class FailingSource: ItemSource, @unchecked Sendable {
    struct Failure: Error {}

    let format = PCMFormat(sampleRate: 8, channelCount: 1)
    let frameCount: Int64? = nil
    private let base: Float
    private var remaining: Int
    private var frame: Int64 = 0

    init(chunks: Int, base: Float) {
        remaining = chunks
        self.base = base
    }

    func begin(epoch: UInt64) {}
    func open() throws -> PCMFormat { format }

    func seek(toFrame frame: Int64) throws -> Int64 {
        self.frame = frame
        return frame
    }

    func nextChunk() throws -> [Float]? {
        guard remaining > 0 else { throw Failure() }
        remaining -= 1
        defer { frame += 2 }
        return [base + Float(frame), base + Float(frame + 1)]
    }

    func interrupt(through epoch: UInt64) {}
    func release() {}
}

/// Which item's failure pauses (ADR-0019 Errors): the one heard, not a next item decode reached
/// early. Eight frames a second on the manual clock; a chunk is a quarter second.
final class TransportFailureTests: XCTestCase {
    private let output = FakeAudioOutput()
    private let timer = ManualPumpTimer()
    private let executor = ManualExecutor()
    private let recorder = EventRecorder()
    private lazy var transport = Transport<String>(output: output, timer: timer, executor: executor) { [recorder] in
        recorder.append($0)
    }

    /// Three seconds, samples 0 to 23.
    private lazy var a = FakeItemSource(format: PCMFormat(sampleRate: 8, channelCount: 1), frames: 24, chunkFrames: 2)
    private let allOfA: [Float] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23]

    private func pump() {
        timer.sync()
        executor.runUntilIdle()
        timer.fire()
        // A dropped next item's flush is queued from inside the pump; wait for it, or it races the test's reads.
        timer.sync()
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

    private var statuses: [TransportStatus] {
        recorder.events.compactMap { if case let .status(status) = $0 { status } else { nil } }
    }

    private var positions: [String] {
        recorder.events.compactMap {
            guard case let .position(item, seconds, _, _) = $0 else { return nil }
            return "\(item) \(seconds)"
        }
    }

    private var failedItems: [String?] {
        recorder.events.compactMap { if case let .failed(item, _) = $0 { item } else { nil } }
    }

    private var crossed: [String] {
        recorder.events.compactMap { if case let .crossed(item, _) = $0 { item } else { nil } }
    }

    /// Every quarter second of `a`, from its start to its end.
    private let positionsOfA = stride(from: 0.0, through: 3, by: 0.25).map { "a \($0)" }

    func testANextItemThatFailsBeforeAnyAudioIsReportedAndTheCurrentPlaysOn() {
        transport.setCurrent(item: "a", source: a)
        transport.setNext(item: "b", source: FailingSource(chunks: 0, base: 1000))
        transport.play()
        pump()
        run(for: 3.5)

        XCTAssertEqual(failedItems, ["b"])
        XCTAssertEqual(heard, allOfA)
        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
        XCTAssertEqual(positions, positionsOfA)
        XCTAssertEqual(crossed, ["a"])

        // The failed item left the window, so a later next item plays on from the end.
        transport.setNext(item: "c", source: FakeItemSource(format: a.format, frames: 4, chunkFrames: 2, base: 2000))
        pump()
        run(for: 1)
        XCTAssertEqual(heard, allOfA + [2000, 2001, 2002, 2003])
        XCTAssertEqual(crossed, ["a", "c"])
    }

    // Its chunks were already written after `a`'s when the failure is pulled, so they are dropped too.
    func testANextItemThatFailsPartwayIsDroppedAndTheCurrentPlaysOn() {
        transport.setCurrent(item: "a", source: a)
        transport.setNext(item: "b", source: FailingSource(chunks: 2, base: 1000))
        transport.play()
        pump()
        run(for: 3.5)

        XCTAssertEqual(failedItems, ["b"])
        XCTAssertEqual(heard, allOfA)
        XCTAssertFalse(statuses.contains(.paused), "\(statuses)")
        XCTAssertEqual(statuses.last, .ended)
        XCTAssertEqual(positions, positionsOfA)
        XCTAssertEqual(crossed, ["a"])
    }

    // Decode is two seconds ahead, so a failure 2.5 s into `b` is pulled once `b` is heard.
    func testANextItemThatFailsOnceItIsHeardPausesAsTheCurrentDoes() {
        transport.setCurrent(item: "a", source: a)
        transport.setNext(item: "b", source: FailingSource(chunks: 10, base: 1000))
        transport.play()
        pump()
        run(for: 4)

        XCTAssertEqual(failedItems, ["b"])
        XCTAssertEqual(crossed, ["a", "b"])
        XCTAssertEqual(statuses, [.buffering, .playing, .paused])
        XCTAssertEqual(output.rate, 0)
    }

    // Decode pulls b's failure 0.25 s before the join, then the live clock crosses it before the
    // drop runs: b is heard by then, so its failure pauses as the current's does.
    func testANextItemThatFailsAsTheClockCrossesTheJoinPausesAsTheCurrentDoes() {
        let output = output, recorder = recorder
        let transport = Transport<String>(output: output, timer: timer, executor: executor) { event in
            recorder.append(event)
            if case .failed = event { output.advanceAfterNextRead(by: 0.5) }
        }
        transport.setCurrent(item: "a", source: a)
        transport.setNext(item: "b", source: FailingSource(chunks: 6, base: 1000))
        transport.play()
        pump()
        run(for: 3.5)
        XCTAssertEqual(failedItems, ["b"])
        XCTAssertEqual(crossed, ["a", "b"])
        XCTAssertEqual(statuses, [.buffering, .playing, .paused])
        XCTAssertEqual(output.rate, 0)
        XCTAssertEqual(output.flushes, [0])
    }

    // The seek runs before decode reaches `b` on its own.
    func testASeekToTheNextItemMakesItsFailurePause() {
        transport.setCurrent(item: "a", source: a)
        transport.setNext(item: "b", source: FailingSource(chunks: 0, base: 1000))
        transport.seek(item: "b", toSeconds: 0)
        transport.play()
        pump()

        XCTAssertEqual(failedItems, ["b"])
        XCTAssertEqual(statuses.last, .paused)
        XCTAssertEqual(output.rate, 0)
    }
}
