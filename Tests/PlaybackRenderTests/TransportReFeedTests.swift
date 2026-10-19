@testable @_spi(Testing) import PlaybackRender
import PlaybackRenderTestSupport
import XCTest

/// A processor change re-feeds only what is queued past the heard frame, by a partial flush: the
/// audio before it plays on, with no `buffering` status and no gap. Eight frames a second; a chunk
/// is a quarter second.
final class TransportReFeedTests: XCTestCase {
    private let mono = PCMFormat(sampleRate: 8, channelCount: 1)
    private let output = FakeAudioOutput()
    private let timer = ManualPumpTimer()
    private let executor = ManualExecutor()
    private let recorder = EventRecorder()
    private lazy var transport = Transport<String>(output: output, timer: timer, executor: executor) { [recorder] in
        recorder.append($0)
    }

    /// Ten seconds, samples 0 to 79.
    private lazy var long = FakeItemSource(format: mono, frames: 80, chunkFrames: 2)
    /// Three seconds, samples 0 to 23.
    private lazy var a = FakeItemSource(format: mono, frames: 24, chunkFrames: 2)
    /// Two seconds, samples 1000 to 1015.
    private lazy var b = FakeItemSource(format: mono, frames: 16, chunkFrames: 2, base: 1000)

    private func pump() {
        timer.sync()
        executor.runUntilIdle()
        timer.fire()
    }

    private func run(for seconds: TimeInterval) {
        for _ in 0..<Int(seconds * 4) {
            output.advance(by: 0.25)
            pump()
        }
    }

    private func play(_ item: String, _ source: FakeItemSource, until clock: TimeInterval) {
        transport.setCurrent(item: item, source: source)
        transport.play()
        pump()
        runUntil(clock)
    }

    // Bounded: a clock that stopped must fail the test, not hang it.
    private func runUntil(_ clock: TimeInterval) {
        for _ in 0..<80 where output.currentTime() < clock { run(for: 0.25) }
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

    private var statuses: [TransportStatus] {
        recorder.events.compactMap { if case let .status(status) = $0 { status } else { nil } }
    }

    private var crossed: [String] {
        recorder.events.compactMap { if case let .crossed(item, _) = $0 { item } else { nil } }
    }

    private func doubled(_ samples: Range<Int>) -> [Float] { samples.map { Float($0) * 2 } }
    private func plain(_ samples: Range<Int>) -> [Float] { samples.map(Float.init) }

    func testALiveParameterChangeIsHeardHalfASecondPastTheHeardFrameWithNoGap() {
        let boost = LiveGainProcessor()
        transport.setProcessors([boost])
        play("a", long, until: 1.0)
        boost.gain = 2
        transport.processorsChanged()
        run(for: 9.25)

        XCTAssertEqual(output.partialFlushes, [1.75])
        XCTAssertEqual(output.flushes, [0], "only the initial flush")
        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
        XCTAssertEqual(gaps, [])
        XCTAssertEqual(heard, plain(0..<14) + doubled(14..<80))
    }

    func testTheHeardPositionIsContinuousAcrossThePartialFlush() {
        let boost = LiveGainProcessor()
        transport.setProcessors([boost])
        play("a", long, until: 1.0)
        boost.gain = 2
        transport.processorsChanged()
        run(for: 9.25)

        let frames = recorder.events.compactMap { event -> Int64? in
            guard case let .position(_, seconds, _, _) = event else { return nil }
            return Int64(seconds * 8)
        }
        XCTAssertEqual(frames, Array(stride(from: Int64(0), through: 80, by: 2)))
    }

    func testTheKeptDepthIsPlayoutTimeSoItScalesWithTheRateAndTheOutputLatency() {
        output.outputLatency = 0.25
        transport.setRate(2)
        let boost = LiveGainProcessor()
        transport.setProcessors([boost])
        play("a", long, until: 1.75)
        boost.gain = 2
        transport.processorsChanged()
        pump()

        // One second of media past the clock, which already runs a latency ahead of what is heard.
        XCTAssertEqual(output.partialFlushes, [3])
    }

    func testAChangeWithNothingWrittenPastTheKeptDepthFlushesNothing() {
        transport.setProcessors([])
        play("a", a, until: 2.75)
        transport.setProcessors([GainProcessor()])
        transport.processorsChanged()
        run(for: 1)

        XCTAssertEqual(output.partialFlushes, [])
        XCTAssertEqual(output.flushes, [0])
        XCTAssertEqual(heard, plain(0..<24))
    }

    func testRapidChangesWhileAFlushIsPendingMakeOneFlushAndWriteNothingInBetween() {
        let boost = LiveGainProcessor()
        transport.setProcessors([boost])
        play("a", long, until: 1.0)
        output.holdsPartialFlushes = true

        for gain in 2...6 {
            boost.gain = Float(gain)
            transport.processorsChanged()
            pump()
        }
        output.advance(by: 0.125)
        pump()

        XCTAssertEqual(output.partialFlushes, [1.5])
        XCTAssertEqual(output.enqueuesDuringPartialFlush, 0)

        output.completePartialFlushes()
        pump()
        run(for: 9)

        XCTAssertEqual(output.partialFlushes, [1.5])
        XCTAssertEqual(output.enqueuesDuringPartialFlush, 0)
        XCTAssertEqual(output.flushes, [0])
        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
        XCTAssertEqual(heard, plain(0..<12) + (12..<80).map { Float($0) * 6 }, "the last gain is the one heard")
    }

    func testACutInsideAChunkMovesToTheChunksEndSoTheReFeedOverlapsNothing() {
        // Three frames a chunk: 0.375 s, so the cut target 2.0 (clock 1.5 at the change) is inside the chunk ending at 2.25.
        let odd = FakeItemSource(format: mono, frames: 80, chunkFrames: 3)
        let boost = LiveGainProcessor()
        transport.setProcessors([boost])
        play("a", odd, until: 1.25)
        boost.gain = 2
        transport.processorsChanged()
        run(for: 9.25)

        XCTAssertEqual(output.partialFlushes, [2.25])
        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
        XCTAssertEqual(gaps, [])
        XCTAssertEqual(heard, plain(0..<18) + doubled(18..<80))
    }

    func testAFailedPartialFlushThatCompletesLateStillAppendsAtTheWrittenEnd() {
        let boost = LiveGainProcessor()
        transport.setProcessors([boost])
        play("a", long, until: 1.0)
        output.holdsPartialFlushes = true
        output.failsPartialFlushes = true
        boost.gain = 2
        transport.processorsChanged()
        pump()
        output.advance(by: 1)
        output.completePartialFlushes()
        pump()
        run(for: 9.25)

        XCTAssertEqual(output.partialFlushes, [1.5])
        XCTAssertEqual(output.flushes, [0])
        XCTAssertEqual(heard, plain(0..<24) + doubled(24..<80), "nothing replayed or skipped")
    }

    // MARK: A shallow queue, as on the iPhone speaker

    /// The renderer takes half a second ahead and cannot replace the half second it has committed to.
    private func useShallowRenderer() {
        output.capacity = 0.5
        output.partialFlushHorizon = 1
    }

    func testAChangeOnAShallowQueueAppendsTheNewChainAtTheWrittenEndWithNoFlushStopOrGap() {
        useShallowRenderer()
        transport.setProcessors([])
        play("a", long, until: 1.0)
        transport.setProcessors([GainProcessor()])
        run(for: 9.25)

        XCTAssertEqual(output.partialFlushes, [])
        XCTAssertEqual(output.flushes, [0], "only the initial flush")
        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
        XCTAssertEqual(gaps, [])
        XCTAssertEqual(heard, plain(0..<12) + doubled(12..<80))
    }

    func testAFailedPartialFlushLeavesTheQueueSoTheNewChainFollowsItWithNoStopOrGap() {
        output.partialFlushHorizon = 100
        let boost = LiveGainProcessor()
        transport.setProcessors([boost])
        play("a", long, until: 1.0)
        boost.gain = 2
        transport.processorsChanged()
        run(for: 9.25)

        XCTAssertEqual(output.partialFlushes, [1.75])
        XCTAssertEqual(output.flushes, [0])
        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
        XCTAssertEqual(gaps, [])
        XCTAssertEqual(heard, plain(0..<24) + doubled(24..<80))
    }

    func testAChangeWhoseFlushWouldReplaceLessThanTheKeptDepthAppendsInstead() {
        // Written to 1.75 at clock 1.0: the cut at 1.5 would replace a quarter second, under the half second kept.
        output.capacity = 0.75
        transport.setProcessors([])
        play("a", long, until: 1.0)
        transport.setProcessors([GainProcessor()])
        pump()
        run(for: 9.25)

        XCTAssertEqual(output.partialFlushes, [])
        XCTAssertEqual(output.flushes, [0])
        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
        XCTAssertEqual(heard, plain(0..<14) + doubled(14..<80))
    }

    func testRapidChangesOnAShallowQueueStackNothingAndTheLastChainIsHeard() {
        output.capacity = 0.75
        output.partialFlushHorizon = 1
        transport.setProcessors([])
        play("a", long, until: 1.0)
        for _ in 0..<5 {
            transport.setProcessors([GainProcessor()])
            pump()
        }
        run(for: 9.25)

        XCTAssertEqual(output.partialFlushes, [])
        XCTAssertEqual(output.flushes, [0])
        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
        XCTAssertEqual(gaps, [])
        XCTAssertEqual(heard.last, 158)
    }

    func testAFailedFlushAfterTheClockPassedTheCutRestartsFromTheHeardFrame() {
        let boost = LiveGainProcessor()
        transport.setProcessors([boost])
        play("a", long, until: 1.0)
        output.holdsPartialFlushes = true
        output.failsPartialFlushes = true
        boost.gain = 2
        transport.processorsChanged()
        pump()
        // The output ran dry under the pending flush, so its clock was rewound: the queue's state is unknown.
        output.advance(by: 4)
        pump()
        output.completePartialFlushes()
        pump()
        run(for: 9.25)

        XCTAssertEqual(output.flushes.count, 2)
        XCTAssertEqual(heard.last, 158)
    }

    func testAChangeAfterTheFlushCompletedMakesTheNextFlush() {
        let boost = LiveGainProcessor()
        transport.setProcessors([boost])
        play("a", long, until: 1.0)
        output.holdsPartialFlushes = true
        boost.gain = 2
        transport.processorsChanged()
        pump()
        output.completePartialFlushes()
        run(for: 1)

        boost.gain = 3
        transport.processorsChanged()
        pump()

        XCTAssertEqual(output.partialFlushes.count, 2)
        XCTAssertEqual(output.flushes, [0])
    }

    func testAFailedPartialFlushAppendsInsteadOfRestarting() {
        let boost = LiveGainProcessor()
        transport.setProcessors([boost])
        play("a", long, until: 1.0)
        output.failsPartialFlushes = true
        boost.gain = 2
        transport.processorsChanged()
        run(for: 9.25)

        XCTAssertEqual(output.partialFlushes, [1.75])
        XCTAssertEqual(output.flushes, [0])
        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
        XCTAssertEqual(heard, plain(0..<24) + doubled(24..<80))
    }

    func testAPartialFlushThatFailsAfterAFullFlushIsIgnored() {
        let boost = LiveGainProcessor()
        transport.setProcessors([boost])
        play("a", long, until: 1.0)
        output.holdsPartialFlushes = true
        output.failsPartialFlushes = true
        boost.gain = 2
        transport.processorsChanged()
        transport.seek(item: "a", toSeconds: 5)
        pump()
        output.completePartialFlushes()
        pump()

        XCTAssertEqual(output.flushes.count, 2, "the seek's flush only")
    }

    func testProcessorChangesAfterTheEndFlushNothing() {
        play("a", a, until: 3.25)
        transport.setProcessors([GainProcessor()])
        transport.processorsChanged()
        run(for: 1)

        XCTAssertEqual(output.partialFlushes, [])
        XCTAssertEqual(output.flushes, [0])
        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
    }

    func testProcessorsChangedWhileFailedFlushesNothing() {
        transport.setProcessors([FixedRateProcessor(sampleRate: 44100)])
        play("a", a, until: 0)
        transport.processorsChanged()
        pump()

        XCTAssertEqual(output.partialFlushes, [])
        XCTAssertEqual(output.flushes, [0])
    }

    func testSetProcessorsAfterAFailureReplaysFromTheHeardFrameWithAFullFlush() {
        transport.setProcessors([FixedRateProcessor(sampleRate: 44100)])
        play("a", a, until: 0)
        transport.setProcessors([GainProcessor()])
        transport.play()
        pump()
        run(for: 3.25)

        XCTAssertEqual(output.partialFlushes, [])
        XCTAssertEqual(heard, doubled(0..<24))
    }

    // MARK: At an item boundary

    private func playAThenBUntil(_ clock: TimeInterval) {
        transport.setCurrent(item: "a", source: a)
        transport.setNext(item: "b", source: b)
        transport.play()
        pump()
        runUntil(clock)
    }

    private let bPlain: [Float] = (1000..<1016).map(Float.init)
    private let bDoubled: [Float] = (1000..<1016).map { Float($0) * 2 }

    func testACutInsideTheFirstItemsTailRejoinsTheNextItemGaplessly() {
        playAThenBUntil(2.0)
        transport.setProcessors([GainProcessor()])
        run(for: 3.5)

        XCTAssertEqual(output.partialFlushes, [2.75])
        XCTAssertEqual(output.flushes, [0])
        XCTAssertEqual(heard, plain(0..<22) + doubled(22..<24) + bDoubled)
        XCTAssertEqual(crossed, ["a", "b"])
        XCTAssertEqual(gaps, [])
    }

    func testACutExactlyAtTheJoinResumesAtTheNextItemsFirstFrame() {
        playAThenBUntil(2.25)
        transport.setProcessors([GainProcessor()])
        run(for: 3.5)

        XCTAssertEqual(output.partialFlushes, [3])
        XCTAssertEqual(heard, plain(0..<24) + bDoubled)
        XCTAssertEqual(crossed, ["a", "b"])
        XCTAssertEqual(gaps, [])
    }

    func testACutJustAfterTheJoinKeepsTheStartOfTheNextItemAndReportsItOnce() {
        playAThenBUntil(3.0)
        XCTAssertEqual(crossed, ["a", "b"])
        transport.setProcessors([GainProcessor()])
        run(for: 2.5)

        XCTAssertEqual(output.partialFlushes, [3.75])
        XCTAssertEqual(output.flushes, [0])
        XCTAssertEqual(heard, plain(0..<24) + Array(bPlain[0..<6]) + Array(bDoubled[6...]))
        XCTAssertEqual(crossed, ["a", "b"], "each item is crossed once")
        XCTAssertEqual(gaps, [])
        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
    }

    func testACutJustBeforeTheJoinWithTheCrossingInTheSameTickReportsItOnce() {
        playAThenBUntil(2.5)
        transport.setProcessors([GainProcessor()])
        run(for: 3)

        XCTAssertEqual(output.partialFlushes, [3.25])
        XCTAssertEqual(heard, plain(0..<24) + Array(bPlain[0..<2]) + Array(bDoubled[2...]))
        XCTAssertEqual(crossed, ["a", "b"])
        XCTAssertEqual(gaps, [])
    }
}
