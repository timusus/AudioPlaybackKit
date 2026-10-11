import Foundation
import PlaybackRender
import XCTest
@testable import PlaybackPlayer

/// Edits while playing, with media3 `ExoPlayerImpl` index arithmetic: the current item plays on
/// through inserts and moves, and the pre-armed next always follows the list.
@MainActor
final class PlayerEditTests: XCTestCase {
    private var rig: PlayerRig!
    private var player: Player<String> { rig.player }

    override func setUp() async throws {
        rig = PlayerRig()
    }

    func testInsertBeforeAtAndAfterTheCurrentKeepsPlayingAndRenumbers() {
        player.setItems(["a", "b", "c"], startIndex: 1)
        player.play()
        rig.run(for: 1)
        let flushes = rig.output.flushes.count

        player.insert(["x"], at: 0)
        XCTAssertEqual(player.currentIndex, 2)
        player.insert(["y"], at: 2)
        XCTAssertEqual(player.currentIndex, 3)
        XCTAssertEqual(rig.factory.calls, ["b", "c"], "the next is still c")
        player.insert(["d"], at: 4)
        XCTAssertEqual(player.currentIndex, 3)
        XCTAssertEqual(player.items, ["x", "a", "y", "b", "d", "c"])
        XCTAssertEqual(rig.factory.calls, ["b", "c", "d"], "d is the next now")

        rig.run(for: 1)
        XCTAssertEqual(player.currentItem, "b")
        XCTAssertEqual(player.position, 2)
        XCTAssertEqual(player.state, .ready)
        XCTAssertEqual(rig.output.flushes.count, flushes)
    }

    func testInsertIntoAnEmptyListSetsIt() {
        player.insert(["a", "b"], at: 0)

        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(rig.factory.calls, ["a", "b"])
    }

    func testMoveTheCurrentAndMoveAcrossItKeepPlaying() {
        player.setItems(["a", "b", "c", "d"])
        player.play()
        rig.run(for: 1)
        let flushes = rig.output.flushes.count

        player.move(from: 0, to: 2)
        XCTAssertEqual(player.items, ["b", "c", "a", "d"])
        XCTAssertEqual(player.currentIndex, 2)
        XCTAssertEqual(rig.factory.calls, ["a", "b", "d"])

        player.move(from: 0, to: 3)
        XCTAssertEqual(player.items, ["c", "a", "d", "b"])
        XCTAssertEqual(player.currentIndex, 1)
        player.move(from: 3, to: 0)
        XCTAssertEqual(player.items, ["b", "c", "a", "d"])
        XCTAssertEqual(player.currentIndex, 2)
        XCTAssertEqual(rig.factory.calls, ["a", "b", "d"], "d stayed next")

        rig.run(for: 1)
        XCTAssertEqual(player.currentItem, "a")
        XCTAssertEqual(player.position, 2)
        XCTAssertEqual(rig.output.flushes.count, flushes)
    }

    func testRemoveALaterItemReArmsTheNext() {
        player.setItems(["a", "b", "c"])
        player.play()
        rig.pump()

        player.remove(at: 1)
        XCTAssertEqual(player.items, ["a", "c"])
        XCTAssertEqual(rig.factory.calls, ["a", "b", "c"])
        player.remove(at: 1)
        XCTAssertFalse(player.hasNext)

        rig.run(for: 11)
        XCTAssertEqual(player.state, .ended)
        let samples = rig.output.enqueues.flatMap(\.samples)
        XCTAssertEqual(samples.max(), 79, "only a was heard: nothing armed after it")
    }

    func testRemoveTheCurrentPlaysItsSuccessorFromTheStart() async {
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 1)
        let written = rig.output.enqueues.count

        player.remove(at: 0)
        XCTAssertEqual(player.items, ["b", "c"])
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(player.currentItem, "b")
        XCTAssertEqual(rig.factory.calls, ["a", "b", "c"], "b was armed, so its source is reused")
        rig.pump()

        XCTAssertEqual(rig.firstSampleWritten(skipping: written), 1000)
        XCTAssertEqual(player.position, 0)
        XCTAssertEqual(player.state, .ready)
        XCTAssertTrue(player.playWhenReady)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 0, to: 0, reason: .seek)])
    }

    func testRemoveTheLastRemainingItemLeavesIdle() async {
        player.setItems(["a"])
        player.play()
        rig.run(for: 1)

        player.remove(at: 0)
        XCTAssertEqual(player.items, [])
        XCTAssertNil(player.currentIndex)
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(player.position, 0)
        XCTAssertNil(player.duration)
        rig.pump()
        XCTAssertEqual(player.state, .idle)

        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 0, to: nil, reason: .seek)])
    }

    // media3 ExoPlayerTest.clearMediaItems_notifiesMediaItemTransition, and the deviation from
    // clearMediaItems_afterReady_transitionsToEnded: an empty list is `.idle` (ADR-0019).
    func testRemoveAllWhilePlayingStopsAndLeavesIdle() async {
        player.setItems(["a", "b"])
        player.play()
        rig.run(for: 1)

        player.removeAll()
        XCTAssertEqual(player.items, [])
        XCTAssertNil(player.currentIndex)
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(player.position, 0)
        XCTAssertNil(player.duration)
        let written = rig.output.enqueues.count
        rig.run(for: 1)
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(rig.output.enqueues.count, written)

        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 0, to: nil, reason: .seek)])
    }

    // The deviation from media3 ExoPlayerTest.clearMediaItemsAndSeek_inStateEnded_remainsInEnded.
    func testClearAndSeekWhileEndedLeavesIdle() async {
        player.setItems(["a"])
        player.play()
        rig.run(for: 11)
        XCTAssertEqual(player.state, .ended)

        player.removeAll()
        player.seek(to: 0)
        rig.run(for: 1)
        XCTAssertEqual(player.state, .idle)
        XCTAssertNil(player.currentIndex)
        XCTAssertEqual(player.position, 0)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 0, to: nil, reason: .seek)])
        XCTAssertEqual(PlayerRig.seeksLanded(events), [])
    }

    // The deviation from media3 ExoPlayerTest.settingMediaItems_withEmptyListAfterReady_transitionsToEnded.
    func testSetItemsEmptyWhilePlayingStopsAndLeavesIdle() async {
        player.setItems(["a", "b"], startIndex: 1)
        player.play()
        rig.run(for: 1)

        player.setItems([])
        XCTAssertEqual(player.items, [])
        XCTAssertNil(player.currentIndex)
        XCTAssertEqual(player.state, .idle)
        let written = rig.output.enqueues.count
        rig.run(for: 1)
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(rig.output.enqueues.count, written)

        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 1, to: nil, reason: .seek)])
    }

    // media3 ExoPlayerTest.stop_modifyingPlaylistRemainsInIdleState_needsPrepareForBuffering.
    func testEditsAfterStopStayIdleUntilPlay() async {
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 1)
        player.stop()
        rig.pump()
        let written = rig.output.enqueues.count

        player.insert(["d"], at: 3)
        player.move(from: 3, to: 1)
        XCTAssertEqual(player.items, ["a", "d", "b", "c"])
        player.remove(at: 0)
        XCTAssertEqual(player.currentItem, "d")
        XCTAssertEqual(player.state, .idle)
        player.seek(to: 0, itemAt: 2)
        player.remove(at: 2)
        XCTAssertEqual(player.currentItem, "d", "the removed last's place falls to the first")
        rig.run(for: 1)
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(rig.factory.calls, ["a", "b"])
        XCTAssertEqual(rig.output.enqueues.count, written)

        player.play()
        rig.pump()
        XCTAssertEqual(player.state, .ready)
        XCTAssertEqual(rig.firstSampleWritten(skipping: written), 3000)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [
            .init(from: 0, to: 0, reason: .seek),
            .init(from: 0, to: 2, reason: .seek),
            .init(from: 2, to: 0, reason: .seek),
        ])
    }

    // media3: removing the current item when it is last ends at the first item, and play restarts it.
    func testRemoveTheCurrentWhenItIsLastEndsAtTheFirstItem() async {
        player.setItems(["a", "b"], startIndex: 1)
        player.play()
        rig.run(for: 1)

        player.remove(at: 1)
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(player.state, .ended)
        rig.pump()
        XCTAssertEqual(player.state, .ended)

        let written = rig.output.enqueues.count
        player.play()
        rig.pump()
        XCTAssertEqual(rig.firstSampleWritten(skipping: written), 0)
        XCTAssertEqual(player.state, .ready)

        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 1, to: 0, reason: .seek)])
    }

    func testReplaceItemsWithTheSameCurrentItemKeepsThePosition() {
        player.setItems(["a", "b", "c"], startIndex: 1)
        player.play()
        rig.run(for: 2)
        let flushes = rig.output.flushes.count

        player.replaceItems(["a", "b", "c"], currentIndex: 1)
        XCTAssertEqual(rig.factory.calls, ["b", "c"], "c stays armed")
        player.replaceItems(["c", "b", "a"], currentIndex: 1)
        XCTAssertEqual(player.items, ["c", "b", "a"])
        XCTAssertEqual(rig.factory.calls, ["b", "c", "a"])

        rig.run(for: 1)
        XCTAssertEqual(player.position, 3)
        XCTAssertEqual(rig.output.flushes.count, flushes)
    }

    func testReplaceItemsWithAnotherCurrentItemRestarts() {
        player.setItems(["a", "b", "c"], startIndex: 1)
        player.play()
        rig.run(for: 2)
        let written = rig.output.enqueues.count

        player.replaceItems(["x", "y"], currentIndex: 0)
        XCTAssertEqual(rig.factory.calls, ["b", "c", "x", "y"])
        XCTAssertEqual(player.position, 0)
        rig.pump()
        XCTAssertEqual(rig.firstSampleWritten(skipping: written), 4000)
        XCTAssertEqual(player.currentItem, "x")
        XCTAssertEqual(player.position, 0)
    }
}
