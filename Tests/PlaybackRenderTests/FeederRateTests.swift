@testable @_spi(Testing) import PlaybackRender
import PlaybackRenderTestSupport
import XCTest

/// Speed is a time-stretch before enqueue: the output plays at rate 1, so a speed change re-feeds like a
/// processor change and the renderer never re-renders. 8 kHz mono in quarter-second chunks, so the
/// stretch finds real pitch periods.
final class FeederRateTests: XCTestCase {
    private let mono = PCMFormat(sampleRate: 8000, channelCount: 1)

    private var output: FakeAudioOutput!
    private var upstream: FakeUpstream!
    private var events: [(event: FeederEvent, clock: TimeInterval)] = []
    private var feeder: Feeder!

    private func makeFeeder(_ items: [FakeUpstream.Item]) {
        output = FakeAudioOutput()
        upstream = FakeUpstream(items, chunkFrames: 2000)
        events = []
        feeder = Feeder(output: output, upstream: upstream) { [unowned self] in
            events.append(($0, output.currentTime()))
        }
    }

    private func item(_ id: Int, seconds: Int64) -> FakeUpstream.Item {
        .init(id: id, frames: seconds * 8000, format: mono)
    }

    private func run(for seconds: TimeInterval) {
        for _ in 0..<Int(seconds * 4) {
            output.advance(by: 0.25)
            feeder.pump()
        }
    }

    private func useShallowRenderer() {
        output.capacity = 0.5
        output.partialFlushHorizon = 1
    }

    private func useDeepRenderer() {
        output.capacity = 10
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

    private var statuses: [FeederStatus] {
        events.compactMap { if case let .status(status) = $0.event { status } else { nil } }
    }

    private func clock(of status: FeederStatus) -> TimeInterval? {
        events.first { if case .status(status) = $0.event { true } else { false } }?.clock
    }

    private var positions: [(position: MediaPositionMap.Position, clock: TimeInterval)] {
        events.compactMap { if case let .position(position) = $0.event { (position, $0.clock) } else { nil } }
    }

    /// Media seconds reported at `clock`.
    private func seconds(at clock: TimeInterval) -> TimeInterval? {
        positions.last { $0.clock <= clock + 1e-9 }?.position.seconds
    }

    private var crossings: [(item: Int, clock: TimeInterval)] {
        events.compactMap { if case let .heard(.item(item, _)) = $0.event { (item, $0.clock) } else { nil } }
    }

    private func ramp(_ item: Int, _ frames: Range<Int64>) -> [Float] {
        frames.map { FakeUpstream.sample(item, $0) }
    }

    private func pos(_ item: Int, _ frame: Int64) -> MediaPositionMap.Position {
        .init(item: item, mediaFrame: frame, sampleRate: 8000)
    }

    // MARK: A speed change plays on

    func testASpeedChangeOnAShallowQueueAppendsWithNoStopRebufferOrGap() throws {
        makeFeeder([item(0, seconds: 20)])
        useShallowRenderer()
        feeder.play()
        run(for: 1)
        feeder.setRate(1.5)
        run(for: 6)

        XCTAssertEqual(output.rateChanges.map(\.rate), [0, 1], "the renderer never re-renders")
        XCTAssertEqual(output.flushes, [])
        XCTAssertEqual(output.partialFlushes, [])
        XCTAssertEqual(statuses, [.buffering, .playing])
        XCTAssertEqual(gaps, [])
        // The written 1.5 s plays out at 1x, then 1.5 media seconds a second.
        XCTAssertEqual(try XCTUnwrap(seconds(at: 3)), 3.75, accuracy: 0.03)
        XCTAssertEqual(try XCTUnwrap(seconds(at: 6)), 8.25, accuracy: 0.03)
    }

    func testASpeedChangeOnADeepQueueCutsAtAChunkEndWithNoStopRebufferOrGap() throws {
        makeFeeder([item(0, seconds: 20)])
        useDeepRenderer()
        feeder.play()
        run(for: 1)
        feeder.setRate(1.5)
        run(for: 6)

        XCTAssertEqual(output.rateChanges.map(\.rate), [0, 1], "the renderer never re-renders")
        XCTAssertEqual(output.flushes, [])
        XCTAssertEqual(output.partialFlushes, [1.5])
        XCTAssertEqual(statuses, [.buffering, .playing])
        XCTAssertEqual(gaps, [])
        XCTAssertEqual(try XCTUnwrap(seconds(at: 3)), 3.75, accuracy: 0.03)
        XCTAssertEqual(try XCTUnwrap(seconds(at: 6)), 8.25, accuracy: 0.03)
    }

    func testThePlayheadIsContinuousAcrossASlowDown() throws {
        makeFeeder([item(0, seconds: 20)])
        useDeepRenderer()
        feeder.play()
        run(for: 1)
        feeder.setRate(1.5)
        run(for: 2)
        feeder.setRate(0.8)
        run(for: 4)

        let steps = zip(positions, positions.dropFirst()).map { $1.position.seconds - $0.position.seconds }
        XCTAssertEqual(steps.filter { $0 < 0 }, [], "never back")
        XCTAssertEqual(steps.filter { $0 > 0.25 * 1.5 + 0.03 }, [], "no jump")
        // The second change cuts at the first chunk end past 3.5 s, so 1.5x plays on until then.
        XCTAssertEqual(try XCTUnwrap(seconds(at: 3.5)), 4.5, accuracy: 0.03)
        let slow = try XCTUnwrap(seconds(at: 6.5)) - XCTUnwrap(seconds(at: 5.5))
        XCTAssertEqual(slow, 0.8, accuracy: 0.03)
        XCTAssertEqual(output.rateChanges.map(\.rate), [0, 1])
        XCTAssertEqual(gaps, [])
    }

    func testRapidChangesWhileAFlushIsPendingFoldIntoOne() throws {
        makeFeeder([item(0, seconds: 20)])
        useDeepRenderer()
        feeder.play()
        run(for: 1)
        output.holdsPartialFlushes = true
        for rate in [1.25, 1.5, 2] {
            feeder.setRate(rate)
            feeder.pump()
        }
        output.completePartialFlushes()
        feeder.pump()
        run(for: 3)

        XCTAssertEqual(output.partialFlushes, [1.5])
        XCTAssertEqual(output.enqueuesDuringPartialFlush, 0)
        XCTAssertEqual(statuses, [.buffering, .playing])
        XCTAssertEqual(try XCTUnwrap(seconds(at: 3)), 4.5, accuracy: 0.03, "the last rate is the one heard")
    }

    // macOS coalesces the 0.1 s pump timer to about 0.2 s: at 3x that tick plays 0.6 s of media.
    func testCoalescedTicksAtThreeTimesNeverRunTheOutputDry() {
        makeFeeder([item(0, seconds: 30)])
        feeder.setRate(3)
        // Decode has just reached half a second when the output could start, then supplies 0.75 s a tick.
        upstream.available = 2
        feeder.play()
        for _ in 0..<25 {
            output.advance(by: 0.2)
            upstream.available = (upstream.available ?? 0) + 3
            feeder.pump()
        }

        XCTAssertEqual(statuses, [.buffering, .playing])
        XCTAssertEqual(gaps, [])
    }

    func testARateChangeAfterTheEndReFeedsNothing() {
        makeFeeder([item(0, seconds: 2)])
        feeder.play()
        run(for: 2.5)
        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
        let written = output.enqueues.count

        feeder.setRate(2)
        feeder.pump()

        XCTAssertEqual(output.enqueues.count, written)
        XCTAssertEqual(output.partialFlushes, [])
        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
    }

    // MARK: Seeks and ends at speed

    func testASeekAtOneAndAHalfStartsOnTheFrameAndRunsAtTheRate() throws {
        try assertSeek(rate: 1.5, mediaAfterTwoSeconds: 6)
    }

    func testASeekAtPointEightStartsOnTheFrameAndRunsAtTheRate() throws {
        try assertSeek(rate: 0.8, mediaAfterTwoSeconds: 4.6)
    }

    private func assertSeek(rate: Double, mediaAfterTwoSeconds: TimeInterval, line: UInt = #line) throws {
        makeFeeder([item(0, seconds: 20)])
        feeder.setRate(rate)
        feeder.play()
        run(for: 1)
        let written = output.enqueues.count, reported = positions.count
        feeder.seek(to: SeekTarget(pos(0, 24000)))
        run(for: 2)

        XCTAssertEqual(positions[reported].position, pos(0, 24000), line: line)
        XCTAssertEqual(output.enqueues[written].samples.first, FakeUpstream.sample(0, 24000), line: line)
        XCTAssertEqual(try XCTUnwrap(seconds(at: 3)), mediaAfterTwoSeconds, accuracy: 0.03, line: line)
        XCTAssertEqual(output.rateChanges.last?.rate, 1, line: line)
    }

    func testThePlayersExtremeRatesStretchToo() throws {
        for (rate, media) in [(4.0, 8.0), (0.25, 0.5)] {
            makeFeeder([item(0, seconds: 20)])
            feeder.setRate(rate)
            feeder.play()
            run(for: 2)

            XCTAssertEqual(try XCTUnwrap(seconds(at: 2)), media, accuracy: 0.03, "\(rate)")
            XCTAssertEqual(gaps, [], "\(rate)")
        }
    }

    func testAGaplessJoinAndTheEndLandAtOneAndAHalf() {
        assertEnd(rate: 1.5, join: 2.75, end: 4)
    }

    func testAGaplessJoinAndTheEndLandAtPointEight() {
        assertEnd(rate: 0.8, join: 5, end: 7.5)
    }

    /// Four seconds then two, so the join is heard at 4 s / rate and the end at 6 s / rate, each at the
    /// first quarter-second pump past it.
    private func assertEnd(rate: Double, join: TimeInterval, end: TimeInterval, line: UInt = #line) {
        makeFeeder([item(0, seconds: 4), item(1, seconds: 2)])
        feeder.setRate(rate)
        feeder.play()
        run(for: 9)

        XCTAssertEqual(crossings.map(\.item), [0, 1], line: line)
        XCTAssertEqual(crossings.last?.clock ?? 0, join, accuracy: 0.26, line: line)
        XCTAssertEqual(clock(of: .ended) ?? 0, end, accuracy: 0.26, line: line)
        XCTAssertEqual(positions.last?.position, pos(1, 16000), line: line)
        XCTAssertEqual(statuses, [.buffering, .playing, .ended], line: line)
        XCTAssertEqual(gaps, [], line: line)
        XCTAssertEqual(Double(heard.count) / 8000, 6 / rate, accuracy: 0.03, line: line)
    }

    /// The real-output auto-flush test's item and changes: three seconds at 48 kHz stereo in 100 ms
    /// chunks, 2x, 1x and 0.5x set as frames 24000, 60000 and 96000 are heard.
    func testChangesMidItemAt48kHzPlayToTheLastFrame() {
        let stereo = PCMFormat(sampleRate: 48000, channelCount: 2)
        output = FakeAudioOutput()
        upstream = FakeUpstream([.init(id: 0, frames: 144_000, format: stereo)], chunkFrames: 4800)
        events = []
        feeder = Feeder(output: output, upstream: upstream) { [unowned self] in
            events.append(($0, output.currentTime()))
        }
        useDeepRenderer()
        feeder.play()
        var changes: [(frame: Int64, rate: Double)] = [(24000, 2), (60000, 1), (96000, 0.5)]
        for _ in 0..<60 where !statuses.contains(.ended) {
            output.advance(by: 0.1)
            feeder.pump()
            if let change = changes.first, (positions.last?.position.mediaFrame ?? 0) >= change.frame {
                changes.removeFirst()
                feeder.setRate(change.rate)
            }
        }

        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
        XCTAssertEqual(positions.last?.position, .init(item: 0, mediaFrame: 144_000, sampleRate: 48000))
        XCTAssertEqual(gaps, [])
    }

    // MARK: Rate 1 is untouched

    func testAtRateOneTheSamplesAndStampsAreTheSourcesExactly() {
        makeFeeder([item(0, seconds: 4)])
        feeder.play()
        run(for: 5)

        XCTAssertEqual(heard, ramp(0, 0..<32000))
        XCTAssertEqual(output.enqueues.map(\.time), stride(from: 0, to: 4, by: 0.25).map { $0 })
    }

    func testBackAtRateOneTheSamplesAreTheSourcesExactlyAgain() {
        makeFeeder([item(0, seconds: 10)])
        useShallowRenderer()
        feeder.play()
        run(for: 1)
        feeder.setRate(1.5)
        run(for: 2)
        feeder.setRate(1)
        run(for: 2)

        // Whole source chunks again, wherever the stretch left the source.
        for enqueue in output.enqueues.suffix(4) {
            let first = Int64(enqueue.samples[0])
            XCTAssertEqual(first % 2000, 0)
            XCTAssertEqual(enqueue.samples, ramp(0, first..<(first + 2000)))
        }
    }
}
