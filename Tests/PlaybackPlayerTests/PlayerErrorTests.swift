import Foundation
import PlaybackRender
import XCTest
@_spi(Testing) @testable import PlaybackPlayer

/// Per-item failures, on the fake output: items are ten seconds at 8 Hz, and decode runs about two
/// seconds ahead of the playhead, so a next item opens while the current one still plays.
@MainActor
final class PlayerErrorTests: XCTestCase {
    private var rig: PlayerRig!
    private var player: Player<String> { rig.player }

    override func setUp() async throws {
        rig = PlayerRig()
    }

    // media3 ExoPlayerTest.playbackErrorAndReprepareDoesNotResetPosition; there is no auto-skip.
    func testACurrentItemFailingMidStreamStopsThereAndPlayRetriesFromThePosition() async {
        rig.factory.failingAtFrame = ["a": 40]
        player.setItems(["a", "b"])
        player.play()
        rig.run(for: 6)

        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(player.error?.kind, .source)
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertTrue(player.playWhenReady)
        let failedAt = player.position
        XCTAssertGreaterThan(failedAt, 2)
        rig.run(for: 2)
        XCTAssertEqual(player.currentIndex, 0, "no skip to b")

        rig.factory.failingAtFrame = [:]
        let written = rig.output.enqueues.count
        player.play()
        rig.pump()
        XCTAssertNil(player.error)
        XCTAssertEqual(player.state, .ready)
        XCTAssertEqual(rig.firstSampleWritten(skipping: written), Float(failedAt * 8))
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.failedIndices(events), [0])
        XCTAssertEqual(PlayerRig.transitions(events), [])
    }

    // media3 ExoPlayerTest.seekAfterPlaybackError: the seek moves the index and position, and play
    // re-prepares there.
    func testASeekAfterAFailureWaitsForPlayAndPlaysFromTheTarget() async {
        rig.factory.failingAtFrame = ["b": 40]
        player.setItems(["a", "b"], startIndex: 1)
        player.play()
        rig.run(for: 6)
        XCTAssertEqual(player.state, .idle)
        XCTAssertNotNil(player.error)

        player.seek(to: 2, itemAt: 0)
        rig.pump()
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(player.position, 2)
        let written = rig.output.enqueues.count

        player.play()
        rig.pump()
        XCTAssertNil(player.error)
        XCTAssertEqual(player.state, .ready)
        XCTAssertEqual(rig.firstSampleWritten(skipping: written), 16)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 1, to: 0, reason: .seek)])
        XCTAssertEqual(PlayerRig.failedIndices(events), [1])
    }

    // media3 ExoPlayerTest.mediaPeriodMaybeThrowPrepareError_isNotThrownUntilPlaybackReachedFailingItem:
    // the error surfaces once the failed item is current, not while the one before it still plays.
    func testANextThatFailsToOpenIsReportedWhenPlaybackReachesIt() async {
        rig.factory.unopenable = ["b"]
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 9)
        XCTAssertNil(player.error)
        XCTAssertTrue(player.isPlaying, "the current plays on")

        rig.run(for: 2)
        XCTAssertEqual(player.currentItem, "b")
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(player.error?.kind, .source)
        XCTAssertTrue(player.playWhenReady)

        rig.factory.unopenable = []
        player.play()
        rig.run(for: 1)
        XCTAssertEqual(player.currentItem, "b")
        XCTAssertEqual(player.position, 1)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 0, to: 1, reason: .auto)])
        XCTAssertEqual(PlayerRig.failedIndices(events), [1])
    }

    func testANextTheFactoryRejectsIsReportedWhenPlaybackReachesIt() async {
        rig.factory.failing = ["b"]
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 9)
        XCTAssertNil(player.error)
        XCTAssertTrue(player.isPlaying)

        rig.run(for: 2)
        XCTAssertEqual(player.currentItem, "b")
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(rig.factory.calls, ["a", "b"], "c is not armed after a failed next")
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 0, to: 1, reason: .auto)])
        XCTAssertEqual(PlayerRig.failedIndices(events), [1])
    }

    // media3 ExoPlayerTest.sampleStreamMaybeThrowError_isNotThrownUntilPlaybackReachedFailingItem and
    // rendererError_whileReadingAhead_isReportedAfterMediaItemTransition.
    func testANextFailingWhileDecodedAheadIsReportedWhenPlaybackReachesIt() async {
        rig.factory.failingAtFrame = ["b": 4]
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 9.5)
        XCTAssertNil(player.error)
        XCTAssertTrue(player.isPlaying)

        rig.run(for: 1.5)
        XCTAssertEqual(player.currentItem, "b")
        XCTAssertEqual(player.state, .idle)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 0, to: 1, reason: .auto)])
        XCTAssertEqual(PlayerRig.failedIndices(events), [1])
    }

    // media3 reports a failure after the transition into its item, whatever moved there.
    func testASeekOrRemoveOntoAnItemThatFailsToMakeReportsTheTransitionFirst() async {
        rig.factory.failing = ["c"]
        player.setItems(["a", "b", "c", "d"])
        player.play()
        rig.run(for: 1)

        player.seek(to: 0, itemAt: 2)
        XCTAssertEqual(player.error?.kind, .source)
        player.seek(to: 0, itemAt: 0)
        player.remove(at: 1)
        player.remove(at: 0)
        XCTAssertEqual(player.currentItem, "c")
        XCTAssertEqual(player.state, .idle)

        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.kinds(events), [
            .itemTransition, .itemFailed, .itemTransition, .itemTransition, .itemFailed,
        ])
        XCTAssertEqual(PlayerRig.failedIndices(events), [2, 0])
    }

    func testAFailedNextTheAppRemovesIsNeverReported() async {
        rig.factory.unopenable = ["b"]
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 9)
        player.remove(at: 1)
        rig.run(for: 2)

        XCTAssertEqual(player.currentItem, "c")
        XCTAssertNil(player.error)
        XCTAssertEqual(player.state, .ready)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.failedIndices(events), [])
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 0, to: 1, reason: .auto)])
    }
}
