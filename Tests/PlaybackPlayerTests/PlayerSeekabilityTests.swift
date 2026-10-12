import Foundation
import XCTest
@_spi(Testing) @testable import PlaybackPlayer

/// The source declares whether it seeks (ADR-0022): an item of unknown length that seeks is not live,
/// and a seek that cannot be made as asked is reported as `seekAdjusted`, never dropped or failed.
@MainActor
final class PlayerSeekabilityTests: XCTestCase {
    private var rig: PlayerRig!
    private var player: Player<String> { rig.player }

    override func setUp() async throws {
        rig = PlayerRig()
    }

    private func playing(_ items: [String] = ["a", "b"], for seconds: TimeInterval = 1) {
        player.setItems(items)
        player.play()
        rig.run(for: seconds)
    }

    // media3 Timeline.Window: isSeekable with durationUs C.TIME_UNSET is not isLive.
    func testASeekableItemOfUnknownLengthIsNotLiveAndSeeks() async {
        rig.factory.unknownLength = ["a"]
        playing()
        XCTAssertNil(player.duration)
        XCTAssertTrue(player.isSeekable)
        XCTAssertFalse(player.isLive)

        let written = rig.output.enqueues.count
        player.seek(to: 5)
        rig.settle()
        rig.pump()

        XCTAssertEqual(player.position, 5)
        XCTAssertEqual(rig.firstSampleWritten(skipping: written), 40)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.seeksLanded(events), [.init(index: 0, position: 5)])
        XCTAssertEqual(PlayerRig.seeksAdjusted(events), [])
    }

    func testALiveItemRefusesASeekAndReportsItStaysPut() async {
        rig.factory.live = ["a"]
        playing()
        XCTAssertTrue(player.isLive)
        XCTAssertFalse(player.isSeekable)
        let flushes = rig.output.flushes.count
        let count = player.discontinuityCount

        player.seek(to: 5)
        rig.pump()

        XCTAssertEqual(rig.output.flushes.count, flushes)
        XCTAssertEqual(player.discontinuityCount, count)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.seeksAdjusted(events), [.init(index: 0, requested: 5, position: 1)])
        XCTAssertEqual(PlayerRig.kinds(events).filter { $0 == .itemFailed || $0 == .seekLanded }, [])
    }

    // Not yet known to be live, so the seek reaches the source; it starts from 0 instead of failing.
    func testALiveItemLoadedAtAPositionStartsFromItsBeginning() async {
        rig.factory.live = ["a"]
        player.setItems(["a"], startPosition: 5)
        rig.pump()

        XCTAssertEqual(rig.firstSampleWritten(skipping: 0), 0)
        XCTAssertEqual(player.position, 0)
        XCTAssertNil(player.error)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.seeksAdjusted(events), [.init(index: 0, requested: 5, position: 0)])
        XCTAssertEqual(PlayerRig.kinds(events).filter { $0 == .itemFailed }, [])
    }

    func testASeekBeforeALiveItemOpensStartsItFromItsBeginning() async {
        rig.factory.live = ["a"]
        player.setItems(["a"])
        player.seek(to: 3)
        rig.pump()

        XCTAssertEqual(rig.firstSampleWritten(skipping: 0), 0)
        XCTAssertEqual(player.position, 0)
        XCTAssertNil(player.error)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.seeksLanded(events), [.init(index: 0, position: 0)])
        XCTAssertEqual(PlayerRig.seeksAdjusted(events), [.init(index: 0, requested: 3, position: 0)])
        XCTAssertEqual(PlayerRig.kinds(events).filter { $0 == .itemFailed }, [])
    }

    func testAnUnseekableItemOfKnownLengthIsNotLiveButRefusesSeeks() async {
        rig.factory.unseekable = ["a"]
        playing()
        XCTAssertEqual(player.duration, 10)
        XCTAssertFalse(player.isLive)
        XCTAssertFalse(player.isSeekable)

        player.seek(by: 3)

        XCTAssertEqual(player.position, 1)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.seeksAdjusted(events), [.init(index: 0, requested: 4, position: 1)])
    }

    func testASeekPastTheDurationIsClampedAndReported() async {
        playing()
        player.seek(to: 30)
        XCTAssertEqual(player.position, 10)

        player.seek(to: -2)
        XCTAssertEqual(player.position, 0)

        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.seeksAdjusted(events), [
            .init(index: 0, requested: 30, position: 10),
            .init(index: 0, requested: -2, position: 0),
        ])
    }

    func testASeekWithinTheItemIsNoAdjustment() async {
        playing()
        player.seek(to: 5)
        rig.run(for: 1)

        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.seeksAdjusted(events), [])
    }

    // media3 DISCONTINUITY_REASON_SEEK_ADJUSTMENT after DISCONTINUITY_REASON_SEEK.
    func testASourceThatLandsElsewhereIsAnAdjustmentAndADiscontinuity() async {
        rig.factory.coarseSeeks = ["a"]
        playing()

        player.seek(to: 5.5)
        XCTAssertEqual(player.position, 5.5)
        let count = player.discontinuityCount
        rig.settle()
        rig.pump()

        XCTAssertEqual(player.position, 5)
        XCTAssertEqual(player.discontinuityCount, count + 1)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.seeksLanded(events), [.init(index: 0, position: 5)])
        XCTAssertEqual(PlayerRig.seeksAdjusted(events), [.init(index: 0, requested: 5.5, position: 5)])
        XCTAssertEqual(PlayerRig.kinds(events).suffix(2), [.seekLanded, .seekAdjusted])
    }

    func testSeekabilityIsForgottenWhenTheNextItemIsLoaded() {
        rig.factory.live = ["a"]
        playing()
        XCTAssertTrue(player.isLive)

        player.skipToNext()
        XCTAssertFalse(player.isLive)
        XCTAssertFalse(player.isSeekable)
        rig.pump()
        XCTAssertTrue(player.isSeekable)
    }

    // media3 STATE_BUFFERING while a read waits on the network, then STATE_READY.
    func testAReadThatWaitsIsBufferingUntilItReturns() {
        let blocked = DispatchSemaphore(value: 0)
        let stall = ReadStall(frame: 16, entered: blocked)
        rig.factory.stalls["a"] = stall
        player.setItems(["a"])
        player.play()

        // Decode runs off the main thread, so the stalled read blocks it and the test pumps on.
        // `blocked` is signalled when a run of decode jobs finishes or the read stalls.
        let decode = DispatchQueue(label: "decode")
        let executor = rig.executor
        for _ in 0..<40 where !stall.hasStalled {
            rig.timer.sync()
            decode.async { executor.runUntilIdle(); blocked.signal() }
            blocked.wait()
            rig.timer.fire()
            rig.player.drainTransportEvents()
            rig.output.advance(by: 0.25)
        }
        XCTAssertTrue(stall.hasStalled)
        for _ in 0..<20 where player.state != .buffering {
            rig.timer.fire()
            rig.player.drainTransportEvents()
            rig.output.advance(by: 0.25)
        }
        XCTAssertEqual(player.state, .buffering)
        XCTAssertTrue(player.playWhenReady)
        XCTAssertNil(player.error)

        stall.release.signal()
        blocked.wait()
        rig.run(for: 1)
        XCTAssertEqual(player.state, .ready)
        XCTAssertTrue(player.isPlaying)
    }
}
