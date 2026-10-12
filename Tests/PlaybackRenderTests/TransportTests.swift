import Foundation
@testable @_spi(Testing) import PlaybackRender
import PlaybackRenderTestSupport
import XCTest

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

    /// All of `a`, then all of `b`, as heard.
    private let allOfA: [Float] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23]
    private let allOfB: [Float] = [
        1000, 1001, 1002, 1003, 1004, 1005, 1006, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014, 1015,
    ]

    private var crossed: [String] {
        recorder.events.compactMap { if case let .crossed(item, _) = $0 { item } else { nil } }
    }

    private var statuses: [TransportStatus] {
        recorder.events.compactMap { if case let .status(status) = $0 { status } else { nil } }
    }

    private var positions: [Heard] {
        recorder.events.compactMap {
            guard case let .position(item, seconds, _, _) = $0 else { return nil }
            return Heard(item: item, frame: Int64(seconds * 8))
        }
    }

    private var failedItems: [String?] {
        recorder.events.compactMap { if case let .failed(item, _) = $0 { item } else { nil } }
    }

    private var recoveries: Int {
        recorder.events.filter { if case .recovered = $0 { true } else { false } }.count
    }

    func testTwoItemsPlayGaplesslyAndReportTheJoinWhenItIsHeard() {
        transport.setCurrent(item: "a", source: a)
        transport.setNext(item: "b", source: b)
        transport.play()
        pump()
        run(for: 6)

        XCTAssertEqual(heard, allOfA + allOfB)
        XCTAssertEqual(crossed, ["a", "b"])
        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
        XCTAssertEqual(positions, [
            Heard(item: "a", frame: 0), Heard(item: "a", frame: 2), Heard(item: "a", frame: 4),
            Heard(item: "a", frame: 6), Heard(item: "a", frame: 8), Heard(item: "a", frame: 10),
            Heard(item: "a", frame: 12), Heard(item: "a", frame: 14), Heard(item: "a", frame: 16),
            Heard(item: "a", frame: 18), Heard(item: "a", frame: 20), Heard(item: "a", frame: 22),
            Heard(item: "b", frame: 0), Heard(item: "b", frame: 2), Heard(item: "b", frame: 4),
            Heard(item: "b", frame: 6), Heard(item: "b", frame: 8), Heard(item: "b", frame: 10),
            Heard(item: "b", frame: 12), Heard(item: "b", frame: 14), Heard(item: "b", frame: 16),
        ])
    }

    // #112: the timer pumped an empty upstream before the first item, which reads as an end.
    func testTicksBeforeAnyItemAreSetNeverReportEnded() {
        transport.play()
        pump()
        run(for: 1)
        transport.setCurrent(item: "a", source: a)
        pump()
        run(for: 4)

        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
        XCTAssertEqual(heard, allOfA)
    }

    // #108
    func testVolumeIsAppliedAtOnceAndClamped() {
        transport.setVolume(0.25)
        timer.sync()
        XCTAssertEqual(output.volume, 0.25)

        transport.setVolume(3)
        timer.sync()
        XCTAssertEqual(output.volume, 1)

        transport.setVolume(-1)
        timer.sync()
        XCTAssertEqual(output.volume, 0)

        transport.setVolume(0.5)
        transport.setVolume(.nan)
        transport.setVolume(.infinity)
        timer.sync()
        XCTAssertEqual(output.volume, 0.5)
    }

    func testVolumeHoldsAcrossAnItemChangeASeekAndARouteChange() {
        transport.setVolume(0.5)
        transport.setCurrent(item: "a", source: a)
        transport.setNext(item: "b", source: b)
        transport.play()
        pump()
        run(for: 1)

        transport.setCurrent(item: "b", source: b)
        pump()
        XCTAssertEqual(output.volume, 0.5, "item change")

        transport.seek(item: "b", toSeconds: 1)
        pump()
        XCTAssertEqual(output.volume, 0.5, "seek")

        output.injectAutoFlush()
        pump()
        run(for: 1)
        XCTAssertEqual(output.volume, 0.5, "route change")
    }

    // #102: after a route-change auto-flush the output stayed silent until a pump took the event,
    // then until another wrote the re-decoded audio: up to two pump intervals.
    func testAnAutoFlushAndTheReDecodeEachWakeThePumpAtOnce() {
        transport.setCurrent(item: "a", source: a)
        transport.play()
        pump()
        run(for: 1)
        let wakes = timer.wakes

        output.injectAutoFlush()
        XCTAssertEqual(timer.wakes, wakes + 1)
        timer.fire()
        XCTAssertEqual(output.rate, 0, "nothing decoded from the flush time yet")
        executor.runUntilIdle()
        XCTAssertEqual(timer.wakes, wakes + 2)
        timer.fire()
        XCTAssertEqual(output.rate, 1)

        run(for: 3)
        XCTAssertEqual(heard, allOfA)
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

        XCTAssertEqual(heard, allOfA)
        XCTAssertEqual(statuses, [.buffering, .playing, .paused, .playing, .ended])
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
        XCTAssertEqual(heard, allOfA)
        XCTAssertEqual(statuses.last, .ended)
    }

    func testSeekWithinAnItemThenBackAcrossAJoinDecodeHadPassed() {
        transport.setCurrent(item: "a", source: a)
        transport.setNext(item: "b", source: b)
        transport.play()
        pump()
        run(for: 0.5)

        transport.seek(item: "a", toSeconds: 2)
        pump()
        run(for: 0.75)
        // B's first frames are already written, so decode is past the join.
        XCTAssertTrue(output.enqueues.contains { $0.samples == [1000, 1001] })

        transport.seek(item: "a", toSeconds: 0.5)
        pump()
        run(for: 6)

        let expected: [Float] = [
            0, 1, 2, 3, 16, 17, 18, 19, 20, 21,
            4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
        ] + allOfB
        XCTAssertEqual(heard, expected)
        XCTAssertEqual(crossed, ["a", "b"])

        // A is behind the item heard, so the sequencer has let it go and the seek does nothing.
        transport.seek(item: "a", toSeconds: 0)
        pump()
        run(for: 1)
        XCTAssertEqual(heard, expected)
        XCTAssertEqual(statuses.last, .ended)
    }

    func testASeekToAnItemAlreadyPassedIsIgnored() {
        transport.setCurrent(item: "a", source: short)
        transport.setNext(item: "b", source: b8)
        transport.play()
        pump()
        run(for: 0.75)
        XCTAssertEqual(crossed, ["a", "b"])

        transport.seek(item: "a", toSeconds: 0)
        pump()
        run(for: 1)

        XCTAssertEqual(heard, [0, 1, 2, 3, 1000, 1001, 1002, 1003, 1004, 1005, 1006, 1007])
        XCTAssertEqual(output.flushes, [0])
        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
    }

    func testSetNextBeforeDecodeReachedTheNextReplacesIt() {
        transport.setCurrent(item: "a", source: short)
        transport.setNext(item: "b", source: b8)
        transport.setNext(item: "c", source: c)
        transport.play()
        pump()
        run(for: 0.75)

        // B was replaced, so the transport has forgotten it.
        transport.seek(item: "b", toSeconds: 0)
        pump()
        run(for: 1)

        XCTAssertEqual(heard, [0, 1, 2, 3, 500, 501, 502, 503, 504, 505, 506, 507])
        XCTAssertEqual(crossed, ["a", "c"])
        XCTAssertEqual(output.flushes, [0])
    }

    func testClearNextBeforeDecodeReachedTheNextRemovesIt() {
        transport.setCurrent(item: "a", source: short)
        transport.setNext(item: "b", source: b8)
        transport.clearNext()
        transport.play()
        pump()
        run(for: 1)

        XCTAssertEqual(heard, [0, 1, 2, 3])
        XCTAssertEqual(crossed, ["a"])
        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
    }

    func testARepeatedItemIsReportedEachTimeAndASeekLandsInTheEarliestStillSet() {
        transport.setCurrent(item: "a", source: short)
        transport.setNext(item: "a", source: FakeItemSource(format: mono, frames: 4, chunkFrames: 2, base: 100))
        transport.play()
        pump()
        run(for: 0.25)

        // The first is still set, so the seek lands there.
        transport.seek(item: "a", toSeconds: 0)
        pump()
        run(for: 0.75)
        XCTAssertEqual(crossed, ["a", "a"])

        // Now only the second is.
        transport.seek(item: "a", toSeconds: 0)
        pump()
        run(for: 1)

        XCTAssertEqual(heard, [0, 1, 0, 1, 2, 3, 100, 101, 100, 101, 102, 103])
        XCTAssertEqual(crossed, ["a", "a"])
        XCTAssertEqual(statuses.last, .ended)
    }

    func testEachPositionCarriesItsSourcesDurationAndSeekability() {
        a.seekable = false
        b.duration = nil
        b.seekable = true
        transport.setCurrent(item: "a", source: a)
        transport.setNext(item: "b", source: b)
        transport.play()
        pump()
        run(for: 6)

        let durations = recorder.events.compactMap { event -> String? in
            guard case let .position(item, _, duration, isSeekable) = event else { return nil }
            return "\(item) \(duration.map { "\($0)" } ?? "nil") \(isSeekable)"
        }
        XCTAssertEqual(Set(durations), ["a 3.0 false", "b nil true"])
    }

    func testAStartIsReportedOnceItsFirstAudioGivesTheFrame() {
        transport.setCurrent(item: "a", source: a, startSeconds: 0.5)
        timer.sync()
        timer.fire()
        XCTAssertEqual(positions, [])

        pump()
        XCTAssertEqual(positions, [Heard(item: "a", frame: 4)])
    }

    /// Ten seconds of `long`, positions every chunk, `skipping` left out.
    private func positionsOfLong(skipping skipped: Range<Int64> = 0..<0) -> [Heard] {
        stride(from: Int64(0), through: 80, by: 2).filter { !skipped.contains($0) }.map { Heard(item: "a", frame: $0) }
    }

    /// Plays `long` for a second, by when frames 0 to 23 are written (two seconds ahead), then calls `change`.
    private func playLongThenChange(processors: [any AudioProcessor], _ change: () -> Void) {
        transport.setProcessors(processors)
        transport.setCurrent(item: "a", source: long)
        transport.play()
        pump()
        run(for: 1)
        change()
        run(for: 9.25)
    }

    // #114, as media3 applies an `AudioProcessor`'s own parameters: live, never through the sink.
    func testALiveParameterChangeIsHeardAfterWhatWasWrittenWithNoFlush() {
        let boost = LiveGainProcessor()
        playLongThenChange(processors: [boost]) { boost.gain = 2 }

        XCTAssertEqual(heard, (0..<24).map(Float.init) + (24..<80).map { Float($0) * 2 })
        XCTAssertEqual(output.flushes, [0])
        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
        XCTAssertEqual(positions, positionsOfLong())
    }

    // #114: a chain change drains the old chain into the queued audio, as media3 `DefaultAudioSink`
    // drains its processors on a configuration change instead of flushing the `AudioTrack`.
    func testAddingAProcessorMidPlaybackAppliesAfterWhatWasWrittenWithNoFlush() {
        playLongThenChange(processors: []) { transport.setProcessors([GainProcessor()]) }

        XCTAssertEqual(heard, (0..<24).map(Float.init) + (24..<80).map { Float($0) * 2 })
        XCTAssertEqual(output.flushes, [0])
        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
        XCTAssertEqual(positions, positionsOfLong())
    }

    func testAddingADroppingProcessorMidPlaybackSkipsThePositionWithNoFlush() {
        playLongThenChange(processors: []) { transport.setProcessors([DropRangesProcessor([0..<8])]) }

        XCTAssertEqual(heard, (0..<24).map(Float.init) + (32..<80).map(Float.init))
        XCTAssertEqual(output.flushes, [0])
        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
        XCTAssertEqual(positions, positionsOfLong(skipping: 24..<32))
    }

    func testRemovingAProcessorMidPlaybackKeepsTheAudioItHeldBack() {
        playLongThenChange(processors: [DelayProcessor(frames: 3)]) { transport.setProcessors([]) }

        XCTAssertEqual(heard, (0..<80).map(Float.init))
        XCTAssertEqual(output.flushes, [0])
        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
        XCTAssertEqual(positions, positionsOfLong())
    }

    // The pending chain is swapped in by the decode job that follows the seek, not lost with the
    // queued audio the seek discards, and it starts at the new position.
    func testAPendingChainRacingASeekIsAppliedOnceFromTheNewPosition() {
        playLongThenChange(processors: []) {
            transport.setProcessors([GainProcessor()])
            transport.seek(item: "a", toSeconds: 5)
            pump()
        }

        XCTAssertEqual(heard, (0..<8).map(Float.init) + (40..<80).map { Float($0) * 2 })
        XCTAssertEqual(output.flushes, [0, 1])
        XCTAssertEqual(statuses.last, .ended)
        XCTAssertEqual(positions.last, Heard(item: "a", frame: 80))
    }

    func testAPendingChainRacingASetCurrentIsAppliedOnceFromTheNewItem() {
        playLongThenChange(processors: []) {
            transport.setProcessors([GainProcessor()])
            transport.setCurrent(item: "b", source: b)
            pump()
        }

        XCTAssertEqual(heard, (0..<8).map(Float.init) + allOfB.map { $0 * 2 })
        XCTAssertEqual(crossed, ["a", "b"])
        XCTAssertEqual(statuses.last, .ended)
    }

    // The output format changes (stereo to mono) at a chunk boundary inside the item: the old chain
    // drains first, and positions stay in media time.
    func testAPendingChainThatChangesTheFormatMidItemLosesAndRepeatsNothing() {
        transport.setCurrent(item: "a", source: FakeItemSource(format: PCMFormat(sampleRate: 8, channelCount: 2), frames: 80, chunkFrames: 2))
        transport.play()
        pump()
        run(for: 1)
        transport.setProcessors([MonoProcessor()])
        run(for: 9.25)

        // Stereo sample f * 2 + c, averaged to f * 2 + 0.5.
        XCTAssertEqual(heard, (0..<48).map(Float.init) + (24..<80).map { Float($0 * 2) + 0.5 })
        XCTAssertEqual(positions, positionsOfLong())
        XCTAssertEqual(output.flushes, [0])
        XCTAssertEqual(statuses.last, .ended)
    }

    func testSetProcessorsAfterAProcessorFailedReplaysFromTheHeardFrame() {
        transport.setProcessors([FixedRateProcessor(sampleRate: 44100)])
        transport.setCurrent(item: "a", source: a)
        transport.play()
        pump()
        XCTAssertEqual(failedItems, ["a"])

        transport.setProcessors([])
        transport.play()
        pump()
        run(for: 3.25)
        XCTAssertEqual(heard, allOfA)
        XCTAssertEqual(statuses.last, .ended)
    }

    func testSetCurrentDropsTheNextItem() {
        transport.setCurrent(item: "a", source: a)
        transport.setNext(item: "b", source: b)
        transport.setCurrent(item: "c", source: FakeItemSource(format: mono, frames: 8, chunkFrames: 2, base: 500))
        transport.play()
        pump()
        run(for: 2)

        XCTAssertEqual(heard, [500, 501, 502, 503, 504, 505, 506, 507])
        XCTAssertEqual(crossed, ["c"])
        XCTAssertEqual(statuses.last, .ended)
    }

    func testSetNextAfterTheEndPlaysOnFromThere() {
        transport.setCurrent(item: "a", source: a)
        transport.play()
        pump()
        run(for: 3.25)
        XCTAssertEqual(statuses.last, .ended)

        transport.setNext(item: "b", source: b8)
        pump()
        run(for: 1.25)

        XCTAssertEqual(heard, [
            0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
            1000, 1001, 1002, 1003, 1004, 1005, 1006, 1007,
        ])
        XCTAssertEqual(crossed, ["a", "b"])
        XCTAssertEqual(statuses, [.buffering, .playing, .ended, .buffering, .playing, .ended])
        // Only setCurrent's: b resumes where the output paused, with nothing re-fed.
        XCTAssertEqual(output.flushes, [0])
        XCTAssertEqual(output.enqueues.first { $0.samples == [1000, 1001] }?.time, 3)
    }

    func testSetNextInTheLastSecondOfThePlayingFinalItemJoinsWithoutAFlush() {
        transport.setCurrent(item: "a", source: short)
        transport.play()
        pump()
        run(for: 0.25)
        XCTAssertEqual(statuses, [.buffering, .playing])

        transport.setNext(item: "b", source: b8)
        pump()
        run(for: 1.5)

        XCTAssertEqual(output.played, [
            .audio(start: 0, format: mono, samples: [0, 1, 2, 3, 1000, 1001, 1002, 1003, 1004, 1005, 1006, 1007]),
        ])
        XCTAssertEqual(crossed, ["a", "b"])
        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
        XCTAssertEqual(output.flushes, [0])
    }

    /// Half a second, samples 0 to 3: decode reaches the next item before the first pump.
    private lazy var short = FakeItemSource(format: mono, frames: 4, chunkFrames: 2)
    /// One second, samples 1000 to 1007.
    private lazy var b8 = FakeItemSource(format: mono, frames: 8, chunkFrames: 2, base: 1000)
    /// One second, samples 500 to 507.
    private lazy var c = FakeItemSource(format: mono, frames: 8, chunkFrames: 2, base: 500)

    /// Decode joins b and fills the sequencer's buffer, and the feeder has pulled none of it.
    private func decodeAheadIntoB() {
        transport.setCurrent(item: "a", source: short)
        transport.setNext(item: "b", source: b8)
        timer.sync()
        executor.runUntilIdle()
    }

    func testSetNextAfterDecodeJoinedTheNextQueuesAfterItAndItStaysSeekable() {
        decodeAheadIntoB()
        transport.setNext(item: "c", source: c)
        transport.play()
        pump()
        run(for: 0.75)

        transport.seek(item: "b", toSeconds: 0.75)
        pump()
        run(for: 1.5)

        XCTAssertEqual(heard, [0, 1, 2, 3, 1000, 1001, 1006, 1007, 500, 501, 502, 503, 504, 505, 506, 507])
        XCTAssertEqual(crossed, ["a", "b", "c"])
        XCTAssertEqual(statuses.last, .ended)
    }

    func testClearNextAfterDecodeJoinedTheNextLeavesItPlayingAndSeekable() {
        decodeAheadIntoB()
        transport.clearNext()
        transport.play()
        pump()
        run(for: 0.75)

        transport.seek(item: "b", toSeconds: 0.75)
        pump()
        run(for: 1)

        XCTAssertEqual(heard, [0, 1, 2, 3, 1000, 1001, 1006, 1007])
        XCTAssertEqual(crossed, ["a", "b"])
        XCTAssertEqual(statuses.last, .ended)
    }

    /// Ten seconds, so decode is still in it a second in.
    private lazy var long = FakeItemSource(format: mono, frames: 80, chunkFrames: 2)

    func testStopInterruptsDecodeFlushesTheOutputAndReportsEnded() {
        transport.setCurrent(item: "a", source: long)
        transport.setNext(item: "b", source: b)
        transport.play()
        pump()
        run(for: 1)
        let events = recorder.events.count

        transport.stop()
        timer.sync()
        XCTAssertEqual(output.rate, 0)
        XCTAssertEqual(output.flushes, [0, 1])
        XCTAssertEqual(long.interrupts, 1)
        XCTAssertEqual(recorder.events.count, events + 1)
        XCTAssertEqual(statuses, [.buffering, .playing, .ended])

        // Nothing is left to play, seek to or follow.
        transport.play()
        transport.seek(item: "a", toSeconds: 0)
        transport.setNext(item: "c", source: c)
        pump()
        run(for: 2)
        XCTAssertEqual(heard, [0, 1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(output.enqueues.count, 12)
        // Only the ignored seek's answer.
        XCTAssertEqual(recorder.events.count, events + 2)
        guard case .sought(item: "a", seconds: 0, applied: false) = recorder.events.last else { return XCTFail("\(recorder.events)") }
    }

    func testDroppingTheTransportStopsTheOutput() {
        var transport: Transport<String>? = Transport(output: output, timer: timer, executor: executor) { _ in }
        transport?.setCurrent(item: "a", source: long)
        transport?.play()
        pump()
        run(for: 0.5)
        XCTAssertEqual(output.rate, 1)

        transport = nil
        timer.sync()
        XCTAssertEqual(output.rate, 0)
        XCTAssertEqual(output.flushes, [0, 0.5])
        XCTAssertEqual(long.interrupts, 1)
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
        XCTAssertEqual(heard, [0, 1, 2, 3, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23])
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

        XCTAssertEqual(heard, allOfA)
        XCTAssertEqual(statuses, [.buffering, .playing, .buffering, .playing, .ended])
    }

    // #100: the owner's call is to land paused after a renderer failure or a media-services reset,
    // with no error; the user's play carries on from the heard frame at the same speed and volume.
    func testARendererFailurePausesWithoutAnErrorAndPlayResumesWhereItWasHeard() {
        transport.setCurrent(item: "a", source: a)
        transport.setVolume(0.5)
        transport.setRate(2)
        transport.play()
        pump()
        run(for: 0.5)

        output.injectFailure()
        pump()
        XCTAssertEqual(output.rebuilds, 1)
        XCTAssertEqual(statuses, [.buffering, .playing, .buffering], "paused, waiting for the restart's decode (#151)")
        pump()
        XCTAssertEqual(statuses, [.buffering, .playing, .buffering, .paused])
        XCTAssertEqual(failedItems, [])
        XCTAssertEqual(recoveries, 1, "a caller learns the transport dropped play on its own")

        transport.play()
        pump()
        XCTAssertEqual(output.rate, 2)
        XCTAssertEqual(output.volume, 0.5)
        run(for: 1.5)
        XCTAssertEqual(heard, allOfA)
        XCTAssertEqual(statuses, [.buffering, .playing, .buffering, .paused, .playing, .ended])
    }

    func testAMediaServicesResetIsReportedAsARecoveryWhilePlayingOrPaused() {
        transport.setCurrent(item: "a", source: a)
        transport.play()
        pump()
        run(for: 0.5)

        output.injectReset()
        pump()
        XCTAssertEqual(recoveries, 1)
        pump()
        XCTAssertEqual(statuses.last, .paused)

        output.injectReset()
        pump()
        XCTAssertEqual(recoveries, 2, "paused already, it is still reported")
        XCTAssertEqual(failedItems, [])
    }

    func testARecoveryThatFailsIsReportedOnlyAsTheFailure() {
        transport.setCurrent(item: "a", source: a)
        transport.play()
        pump()
        run(for: 0.5)

        output.injectFailure()
        pump()
        output.injectFailure()
        pump()
        XCTAssertEqual(recoveries, 1)
        XCTAssertEqual(failedItems, [nil])
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
        XCTAssertEqual(heard, allOfB)
        // A's two chunks reached the paused playhead before it failed, so it was current.
        XCTAssertEqual(crossed, ["a", "b"])
        XCTAssertEqual(failedItems, ["a"])
    }

    /// The real queue, timer and decode executor. Calls from many threads are serialised, and those
    /// from one thread run in its order: the last `setRate` before `play` is the rate it plays at.
    func testCallsFromManyThreadsRunOffTheCallersThreadAndInEachThreadsOrder() {
        let output = FakeAudioOutput()
        let playing = expectation(description: "playing")
        playing.assertForOverFulfill = false
        let crossedB = expectation(description: "crossed b")
        let transport = Transport<String>(output: output, timer: DispatchPumpTimer(), executor: SerialQueueExecutor()) { event in
            XCTAssertFalse(Thread.isMainThread)
            switch event {
            case .status(.playing): playing.fulfill()
            case .crossed(item: "b", _): crossedB.fulfill()
            default: break
            }
        }
        transport.setCurrent(item: "a", source: FakeItemSource(format: mono, frames: 4, chunkFrames: 2))
        transport.setNext(item: "b", source: FakeItemSource(format: mono, frames: 4, chunkFrames: 2, base: 1000))

        // No play among them, so `playing` can only come from the one after.
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            switch index % 3 {
            case 0: transport.setRate(1 + Double(index % 4) / 4)
            case 1: transport.seek(item: "a", toSeconds: Double(index % 4) / 8)
            default: transport.pause()
            }
        }
        transport.setRate(1)
        transport.play()
        wait(for: [playing], timeout: 5)
        // The clock stands still until advanced, so nothing has paused it since.
        XCTAssertEqual(output.rate, 1)

        // All of b written first, so the advance lands inside written audio, past the join.
        let bWritten = expectation(for: NSPredicate { _, _ in
            output.enqueues.contains { $0.samples == [1002, 1003] }
        }, evaluatedWith: nil)
        wait(for: [bWritten], timeout: 5)
        output.advance(by: 0.75)
        wait(for: [crossedB], timeout: 5)
    }
}
