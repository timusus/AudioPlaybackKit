@testable import PlaybackRender
import XCTest

/// The feeder against the fake output's manual clock: no test sleeps, and every pump is explicit.
/// Four frames a second keeps every time exact in binary; the default 2 s target is 8 frames.
final class FeederTests: XCTestCase {
    private let mono = PCMFormat(sampleRate: 4, channelCount: 1)
    private let stereo = PCMFormat(sampleRate: 8, channelCount: 2)

    private var output: FakeAudioOutput!
    private var upstream: FakeUpstream!
    private var events: [FeederEvent] = []
    private var feeder: Feeder!

    private func makeFeeder(_ items: [FakeUpstream.Item], chunkFrames: Int64 = 2, latency: TimeInterval = 0) {
        output = FakeAudioOutput()
        output.outputLatency = latency
        upstream = FakeUpstream(items, chunkFrames: chunkFrames)
        events = []
        feeder = Feeder(output: output, upstream: upstream) { [unowned self] in events.append($0) }
    }

    private func item(_ id: Int, _ frames: Int64, _ format: PCMFormat? = nil) -> FakeUpstream.Item {
        .init(id: id, frames: frames, format: format ?? mono)
    }

    /// Plays on in quarter-second steps, pumping after each.
    private func run(for seconds: TimeInterval) {
        for _ in 0..<Int(seconds * 4) {
            output.advance(by: 0.25)
            feeder.pump()
        }
    }

    /// The first channel of everything heard, silence skipped.
    private var heard: [Float] {
        output.played.flatMap { span -> [Float] in
            guard case let .audio(_, format, samples) = span else { return [] }
            return stride(from: 0, to: samples.count, by: format.channelCount).map { samples[$0] }
        }
    }

    private func ramp(_ item: Int, _ frames: Range<Int64>) -> [Float] {
        frames.map { FakeUpstream.sample(item, $0) }
    }

    private var statuses: [FeederStatus] {
        events.compactMap { if case let .status(status) = $0 { status } else { nil } }
    }

    private var positions: [MediaPositionMap.Position] {
        events.compactMap { if case let .position(position) = $0 { position } else { nil } }
    }

    private var crossed: [Int] {
        events.compactMap { if case let .crossed(item) = $0 { item } else { nil } }
    }

    private var failures: [any Error] {
        events.compactMap { if case let .failed(error) = $0 { error } else { nil } }
    }

    private func pos(_ item: Int, _ frame: Int64) -> MediaPositionMap.Position {
        .init(item: item, mediaFrame: frame)
    }

    func testStampsAreContiguousAcrossChunksAndAFormatChange() {
        makeFeeder([item(0, 4), item(1, 8, stereo)])
        feeder.pump()

        XCTAssertEqual(output.enqueues.map(\.time), [0, 0.5, 1, 1.25, 1.5, 1.75])
        XCTAssertEqual(output.enqueues.map(\.format), [mono, mono, stereo, stereo, stereo, stereo])
    }

    func testDepthIsHeldAtTheTargetAsTheClockAdvances() {
        makeFeeder([item(0, 80)], chunkFrames: 1)
        feeder.play()

        for _ in 0..<8 {
            output.advance(by: 0.25)
            feeder.pump()
            let last = output.enqueues.last!
            XCTAssertEqual(last.time + 0.25 - output.currentTime(), 2)
        }
        XCTAssertEqual(statuses, [.buffering, .playing])
    }

    func testAnUnderrunPausesAtTheWrittenEndAndResumesWithoutLosingFrames() {
        makeFeeder([item(0, 16)])
        upstream.available = 2
        feeder.play()
        output.advance(by: 1.5)
        feeder.pump()

        XCTAssertEqual(output.currentTime(), 1, "re-anchored at the written end")
        XCTAssertEqual(output.rate, 0)
        XCTAssertEqual(statuses, [.buffering, .playing, .buffering])

        upstream.available = nil
        feeder.pump()
        XCTAssertEqual(statuses, [.buffering, .playing, .buffering, .playing])
        run(for: 4)
        XCTAssertEqual(heard, ramp(0, 0..<16))
        XCTAssertEqual(statuses.last, .ended)
    }

    func testEndOfStreamReportsEndedNotBuffering() {
        makeFeeder([item(0, 4), item(1, 0)])
        feeder.play()
        run(for: 1.5)

        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
        XCTAssertEqual(positions.last, pos(1, 0))
        XCTAssertEqual(crossed, [0, 1])
        XCTAssertEqual(heard, ramp(0, 0..<4))
        XCTAssertEqual(output.rate, 0)
    }

    // iOS reports an output latency, so the heard playhead trails the clock by it.
    func testWithOutputLatencyTheEndIsHeardBeforeEnded() {
        makeFeeder([item(0, 8)], latency: 0.25)
        feeder.play()
        run(for: 3)

        XCTAssertEqual(positions.map(\.mediaFrame), [0, 1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(crossed, [0])
        XCTAssertEqual(statuses, [.buffering, .playing, .ended])
        guard case .status(.ended)? = events.last else { return XCTFail("ended is not last: \(events)") }
        XCTAssertEqual(heard, ramp(0, 0..<8))
        XCTAssertEqual(output.rate, 0)
    }

    func testWithOutputLatencyAnUnderrunResumesWithNoLostOrRepeatedFrames() {
        makeFeeder([item(0, 16)], latency: 0.25)
        upstream.available = 2
        feeder.play()
        run(for: 1.5)

        XCTAssertEqual(output.currentTime(), 1, "re-anchored at the written end")
        XCTAssertEqual(output.rate, 0)
        XCTAssertEqual(positions.map(\.mediaFrame), [0, 1, 2, 3, 4])
        XCTAssertEqual(statuses, [.buffering, .playing, .buffering])

        upstream.available = nil
        feeder.pump()
        run(for: 4)
        XCTAssertEqual(heard, ramp(0, 0..<16))
        XCTAssertEqual(positions.map(\.mediaFrame), Array(0...16))
        XCTAssertEqual(statuses, [.buffering, .playing, .buffering, .playing, .ended])
    }

    func testAnAutoFlushMidItemResuppliesFromTheFlushPosition() {
        makeFeeder([item(0, 40)])
        feeder.play()
        run(for: 1)
        output.injectAutoFlush()
        feeder.pump()

        XCTAssertEqual(upstream.resupplies, [pos(0, 4)])
        run(for: 10)
        XCTAssertEqual(heard, ramp(0, 0..<40))
        XCTAssertEqual(positions.map(\.mediaFrame), Array(0...40))
    }

    // #102: the flush time is where the output dropped audio, already on the clock's timeline, so
    // re-feeding a latency earlier replayed that much on every iPhone route change.
    func testWithOutputLatencyAnAutoFlushResuppliesFromTheFlushTimeNotALatencyEarlier() {
        makeFeeder([item(0, 40)], latency: 0.25)
        feeder.play()
        run(for: 1)
        output.injectAutoFlush()
        feeder.pump()

        XCTAssertEqual(upstream.resupplies, [pos(0, 4)])
        XCTAssertEqual(output.enqueues.last { $0.time == 1 }?.samples.first, FakeUpstream.sample(0, 4))
        run(for: 10)
        XCTAssertEqual(heard, ramp(0, 0..<40))
    }

    func testAStallTakesTheSameRecoveryPath() {
        makeFeeder([item(0, 40)])
        feeder.play()
        run(for: 1)
        output.injectStall()
        output.advance(by: 0.5)
        feeder.pump()

        XCTAssertEqual(upstream.resupplies, [pos(0, 4)])
        XCTAssertEqual(output.flushes, [1.5])
        run(for: 10)
        XCTAssertEqual(heard, ramp(0, 0..<40))
        XCTAssertEqual(positions.map(\.mediaFrame), Array(0...40))
    }

    // Podcasts #396: the engine played the pre-seek audio still queued when resumed after a paused seek.
    func testASeekWhilePausedLeavesNoStaleAudioOrPosition() {
        makeFeeder([item(0, 40)])
        feeder.play()
        run(for: 1)
        feeder.pause()
        feeder.seek(to: pos(0, 20))

        XCTAssertEqual(positions.last, pos(0, 20))
        XCTAssertEqual(statuses.last, .paused)
        feeder.play()
        run(for: 0.5)
        XCTAssertEqual(heard, ramp(0, 0..<4) + ramp(0, 20..<22))
        XCTAssertEqual(positions.last, pos(0, 22))
    }

    func testASpeedChangeWithOldSpeedAudioQueuedKeepsThePositionContinuous() {
        makeFeeder([item(0, 40)])
        feeder.play()
        output.advance(by: 0.5)
        feeder.pump()
        feeder.setRate(2)
        output.advance(by: 0.5)
        feeder.pump()

        XCTAssertEqual(positions, [pos(0, 0), pos(0, 2), pos(0, 6)])
        XCTAssertEqual(heard, ramp(0, 0..<6))
        XCTAssertEqual(output.rate, 2)
    }

    // macOS coalesces the 0.1 s pump timer to about 0.2 s: at 3x that tick plays 0.6 s of audio, more
    // than a resume depth counted in media time.
    func testCoalescedTicksAtThreeTimesNeverRunTheOutputDry() {
        let tenths = PCMFormat(sampleRate: 10, channelCount: 1)
        makeFeeder([item(0, 400, tenths)], chunkFrames: 1)
        feeder.setRate(3)
        // Decode has just reached half a second when the output could start, then supplies 0.8 s a tick.
        upstream.available = 5
        feeder.play()
        for _ in 0..<25 {
            output.advance(by: 0.2)
            upstream.available = (upstream.available ?? 0) + 8
            feeder.pump()
        }

        XCTAssertEqual(statuses, [.buffering, .playing])
        let gaps = output.played.filter { if case let .silence(_, duration) = $0 { duration > 1e-6 } else { false } }
        XCTAssertEqual(gaps, [])
    }

    // Started at 1x with only the resume depth queued, a switch to 3x must refill before the next
    // tick, which plays more than that depth.
    func testASpeedUpRefillsBeforeTheNextTick() {
        makeFeeder([item(0, 40)])
        upstream.available = 1
        feeder.play()
        upstream.available = nil
        feeder.setRate(3)
        output.advance(by: 0.25)
        feeder.pump()

        XCTAssertEqual(statuses, [.buffering, .playing])
        XCTAssertEqual(output.played.filter { if case .silence = $0 { true } else { false } }, [])
    }

    // #102: the iPhone clock steps back about 50 ms on a rate change, an interruption's resume and a
    // late auto-flush; an app counting listening time from position deltas must never see one go back.
    func testThePositionHoldsWhenTheClockStepsBackOnARateChange() {
        makeFeeder([item(0, 40)])
        feeder.play()
        run(for: 1)
        feeder.setRate(2)
        output.stepClockBack(by: 0.25)
        feeder.pump()
        run(for: 5)

        XCTAssertEqual(positions.map(\.mediaFrame), Array(0...4) + Array(stride(from: 5, through: 39, by: 2)) + [40])
    }

    func testThePositionHoldsWhenTheClockStepsBackOnResume() {
        makeFeeder([item(0, 40)])
        feeder.play()
        run(for: 1)
        feeder.pause()
        output.stepClockBack(by: 0.25)
        feeder.play()
        run(for: 10)

        XCTAssertEqual(positions.map(\.mediaFrame), Array(0...40))
        XCTAssertEqual(heard, ramp(0, 0..<40))
    }

    func testThePositionHoldsWhenALateAutoFlushReAnchorsBehindIt() {
        makeFeeder([item(0, 40)])
        feeder.play()
        run(for: 1.25)
        output.injectAutoFlush(at: 1)
        feeder.pump()

        XCTAssertEqual(upstream.resupplies, [pos(0, 4)])
        run(for: 10)
        XCTAssertEqual(positions.map(\.mediaFrame), Array(0...40))
    }

    func testASeekWhilePlayingStillMovesThePositionBack() {
        makeFeeder([item(0, 40)])
        feeder.play()
        run(for: 2)
        feeder.seek(to: pos(0, 2))
        run(for: 0.5)

        XCTAssertEqual(positions.map(\.mediaFrame), Array(0...8) + [2, 3, 4])
    }

    func testAZeroFrameItemIsStillReportedCrossed() {
        makeFeeder([item(0, 2), item(1, 0), item(2, 2)])
        feeder.play()
        XCTAssertEqual(crossed, [0])
        run(for: 0.5)
        XCTAssertEqual(crossed, [0, 1, 2])
    }

    func testARejectedFormatSurfacesAnErrorAndDoesNotSpin() {
        makeFeeder([item(0, 4), item(1, 8, stereo)])
        output.reject(stereo)
        feeder.play()
        let pulls = upstream.pulls
        run(for: 2)

        XCTAssertEqual(failures.map { $0 as? AudioOutputError }, [.formatRejected(stereo)])
        XCTAssertEqual(upstream.pulls, pulls)
        XCTAssertEqual(heard, [])
        XCTAssertEqual(output.rate, 0)
        XCTAssertEqual(statuses, [.buffering, .paused])
    }

    // MARK: Renderer failure (#100)

    func testARendererFailureWhilePlayingRebuildsOnceAndLandsPausedAtTheHeardFrame() {
        makeFeeder([item(0, 40)])
        feeder.setRate(2)
        feeder.play()
        run(for: 0.5)
        output.injectFailure()
        feeder.pump()

        XCTAssertEqual(output.rebuilds, 1)
        XCTAssertEqual(upstream.resupplies, [pos(0, 4)])
        XCTAssertEqual(statuses, [.buffering, .playing, .paused])
        XCTAssertEqual(output.rate, 0)
        XCTAssertTrue(failures.isEmpty)

        feeder.play()
        XCTAssertEqual(output.rate, 2, "resumes at the stored speed")
        run(for: 5)
        XCTAssertEqual(heard, ramp(0, 0..<40))
        XCTAssertEqual(positions.map(\.mediaFrame), positions.map(\.mediaFrame).sorted())
        XCTAssertEqual(positions.last, pos(0, 40))
        XCTAssertEqual(statuses, [.buffering, .playing, .paused, .buffering, .playing, .ended])
    }

    func testAFailedEnqueueTakesTheSameRecoveryPath() {
        makeFeeder([item(0, 40)])
        feeder.play()
        run(for: 1)
        output.injectFailure(reported: false)
        output.advance(by: 0.25)
        feeder.pump()

        XCTAssertEqual(output.rebuilds, 1)
        // The failed renderer went silent at 1 s; the clock it ran on is all there is to resume from.
        XCTAssertEqual(upstream.resupplies, [pos(0, 5)])
        XCTAssertEqual(statuses, [.buffering, .playing, .paused])
        XCTAssertTrue(failures.isEmpty)

        feeder.play()
        run(for: 10)
        XCTAssertEqual(heard, ramp(0, 0..<4) + ramp(0, 5..<40))
        XCTAssertEqual(output.rebuilds, 1)
    }

    func testARendererFailureWhilePausedRebuildsAndStaysPaused() {
        makeFeeder([item(0, 40)])
        feeder.play()
        run(for: 1)
        feeder.pause()
        output.injectFailure()
        feeder.pump()

        XCTAssertEqual(output.rebuilds, 1)
        XCTAssertEqual(upstream.resupplies, [pos(0, 4)])
        XCTAssertEqual(statuses, [.buffering, .playing, .paused])

        feeder.play()
        run(for: 10)
        XCTAssertEqual(heard, ramp(0, 0..<40))
        XCTAssertEqual(positions.map(\.mediaFrame), Array(0...40))
    }

    // media3's pendingRecoverableRendererError: one recovery, and a second error before playing
    // again stops with the error rather than rebuilding in a loop.
    func testASecondFailureBeforePlayingAgainSurfacesWithoutAnotherRebuild() {
        makeFeeder([item(0, 40)])
        feeder.play()
        run(for: 1)
        output.injectFailure()
        feeder.pump()
        output.injectFailure()
        feeder.pump()
        feeder.play()
        run(for: 2)

        XCTAssertEqual(output.rebuilds, 1)
        XCTAssertEqual(failures.map { $0 as? AudioOutputError }, [.rendererFailed])
        XCTAssertEqual(heard, ramp(0, 0..<4))
        XCTAssertEqual(output.rate, 0)
    }

    // iOS: the old renderer's KVO failure, a pump that rebuilds, then the reset notification.
    func testAResetAfterTheFailureItCausedRebuildsAgainWithoutFailing() {
        makeFeeder([item(0, 40)])
        feeder.play()
        run(for: 1)
        output.injectFailure()
        feeder.pump()
        output.injectReset()
        feeder.pump()

        XCTAssertEqual(output.rebuilds, 2)
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(upstream.resupplies, [pos(0, 4), pos(0, 4)])
        XCTAssertEqual(statuses, [.buffering, .playing, .paused])
        XCTAssertEqual(output.rate, 0)

        feeder.play()
        run(for: 10)
        XCTAssertEqual(heard, ramp(0, 0..<40))
    }

    func testAFailureAndAResetBeforeOnePumpRebuildOnce() {
        makeFeeder([item(0, 40)])
        feeder.play()
        run(for: 1)
        output.injectFailure()
        output.injectReset()
        feeder.pump()

        XCTAssertEqual(output.rebuilds, 1)
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(upstream.resupplies, [pos(0, 4)])
    }

    func testAFailureOfTheRebuiltRendererAfterAResetStillSurfaces() {
        makeFeeder([item(0, 40)])
        feeder.play()
        run(for: 1)
        output.injectReset()
        feeder.pump()
        output.injectFailure()
        feeder.pump()
        feeder.play()
        run(for: 2)

        XCTAssertEqual(output.rebuilds, 1)
        XCTAssertEqual(failures.map { $0 as? AudioOutputError }, [.rendererFailed])
        XCTAssertEqual(output.rate, 0)
    }

    func testAFailureAfterPlayingAgainRecoversAgain() {
        makeFeeder([item(0, 40)])
        feeder.play()
        run(for: 1)
        output.injectFailure()
        feeder.pump()
        feeder.play()
        run(for: 1)
        output.injectFailure()
        feeder.pump()

        XCTAssertEqual(output.rebuilds, 2)
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(upstream.resupplies, [pos(0, 4), pos(0, 8)])
        XCTAssertEqual(statuses, [.buffering, .playing, .paused, .buffering, .playing, .paused])
    }

    func testARebuildThatThrowsSurfacesTheError() {
        struct NoRenderer: Error, Equatable {}
        makeFeeder([item(0, 40)])
        output.failRebuilds(with: NoRenderer())
        feeder.play()
        run(for: 1)
        output.injectFailure()
        feeder.pump()
        run(for: 1)

        XCTAssertEqual(output.rebuilds, 1)
        XCTAssertEqual(failures.map { $0 as? NoRenderer }, [NoRenderer()])
        XCTAssertEqual(statuses, [.buffering, .playing, .paused])
        XCTAssertEqual(output.rate, 0)
    }

    func testAFailureAndAnAutoFlushBeforeOnePumpRestartOnceFromTheEarlierTime() {
        makeFeeder([item(0, 40)])
        feeder.play()
        run(for: 1.25)
        output.injectAutoFlush(at: 1)
        output.injectFailure()
        feeder.pump()

        XCTAssertEqual(output.rebuilds, 1)
        XCTAssertEqual(upstream.resupplies, [pos(0, 4)])
        XCTAssertEqual(statuses, [.buffering, .playing, .paused])
    }

    func testAFailureRacingASeekLandsPausedAtTheSeekTarget() {
        makeFeeder([item(0, 40)])
        feeder.play()
        run(for: 1)
        output.injectFailure()
        feeder.seek(to: pos(0, 20))

        XCTAssertEqual(output.rebuilds, 1)
        XCTAssertEqual(upstream.resupplies.last, pos(0, 20))
        XCTAssertEqual(statuses.last, .paused)
        XCTAssertEqual(positions.last, pos(0, 20))

        feeder.play()
        run(for: 1)
        XCTAssertEqual(heard, ramp(0, 0..<4) + ramp(0, 20..<24))
    }
}
