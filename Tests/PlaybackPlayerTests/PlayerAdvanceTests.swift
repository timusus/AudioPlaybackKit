import Foundation
import PlaybackRender
import XCTest
@_spi(Testing) @testable import PlaybackPlayer

/// The advance at the end of an item: repeat modes, the end of the list and pause at end, on the
/// fake output. Items are ten seconds at 8 Hz, and decode runs about two seconds ahead of the playhead.
@MainActor
final class PlayerAdvanceTests: XCTestCase {
    private var rig: PlayerRig!
    private var player: Player<String> { rig.player }

    override func setUp() async throws {
        rig = PlayerRig()
    }

    // media3 ExoPlayerTest.repeatModeChanges, transitions with REPEAT then AUTO.
    func testRepeatOneReplaysTheCurrentItemUntilItIsTurnedOff() async {
        player.setItems(["a", "b"])
        player.repeatMode = .one
        player.play()
        rig.run(for: 21)
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(player.position, 1)

        player.repeatMode = .off
        rig.run(for: 10)
        XCTAssertEqual(player.currentItem, "b")
        XCTAssertEqual(player.position, 1)

        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [
            .init(from: 0, to: 0, reason: .repeat),
            .init(from: 0, to: 0, reason: .repeat),
            .init(from: 0, to: 1, reason: .auto),
        ])
    }

    func testRepeatAllWrapsFromTheLastItemToTheFirst() async {
        player.setItems(["a", "b"])
        player.repeatMode = .all
        player.play()
        rig.run(for: 21)

        XCTAssertEqual(player.currentItem, "a")
        XCTAssertEqual(player.position, 1)
        XCTAssertNotEqual(player.state, .ended)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [
            .init(from: 0, to: 1, reason: .auto),
            .init(from: 1, to: 0, reason: .auto),
        ])
    }

    // media3 reports a wrap onto the same item as REPEAT.
    func testRepeatAllWithOneItemIsARepeat() async {
        player.setItems(["a"])
        player.repeatMode = .all
        player.play()
        rig.run(for: 11)

        XCTAssertEqual(player.position, 1)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 0, to: 0, reason: .repeat)])
    }

    func testTurningRepeatOffAtTheLastItemEnds() async {
        player.setItems(["a", "b"], startIndex: 1)
        player.repeatMode = .all
        player.play()
        rig.run(for: 1)
        player.repeatMode = .off
        rig.run(for: 10)

        XCTAssertEqual(player.currentIndex, 1)
        XCTAssertEqual(player.state, .ended)
        let samples = rig.output.enqueues.flatMap(\.samples)
        XCTAssertEqual(samples.min(), 1000, "a was armed, then cleared before decode reached it")
    }

    func testSkipsWrapUnderRepeatAllAndTreatRepeatOneAsOff() {
        player.setItems(["a", "b"], startIndex: 1)
        player.repeatMode = .one
        XCTAssertFalse(player.hasNext)
        XCTAssertTrue(player.hasPrevious)

        player.repeatMode = .all
        XCTAssertTrue(player.hasNext)
        player.skipToNext()
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertTrue(player.hasPrevious)
        player.skipToPrevious()
        XCTAssertEqual(player.currentIndex, 1)
    }

    // media3 ExoPlayerTest.seekToNextPrevious_singleItemRepeat_notifiesMediaItemTransition.
    func testASkipThatWrapsOntoTheSameItemRestartsItAsATransition() async {
        player.setItems(["a"])
        player.repeatMode = .all
        player.play()
        rig.run(for: 3)
        let written = rig.output.enqueues.count

        player.skipToNext()
        XCTAssertEqual(player.position, 0)
        rig.pump()
        XCTAssertEqual(rig.firstSampleWritten(skipping: written), 0)
        player.skipToPrevious()

        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [
            .init(from: 0, to: 0, reason: .seek),
            .init(from: 0, to: 0, reason: .seek),
        ])
    }

    func testPlayOnEndedRestartsTheCurrentItemFromZero() {
        player.setItems(["a", "b"])
        player.play()
        rig.run(for: 21)
        XCTAssertEqual(player.state, .ended)
        let written = rig.output.enqueues.count

        player.play()
        rig.run(for: 1)
        XCTAssertEqual(rig.firstSampleWritten(skipping: written), 1000)
        XCTAssertEqual(player.currentIndex, 1)
        XCTAssertEqual(player.position, 1)
        XCTAssertEqual(player.state, .ready)
    }

    // media3 ExoPlayerTest.addMediaSource_toEndedPlaylist_remainsInEndedAndNeedsSeekForBuffering.
    func testAddingToAnEndedListStaysEndedUntilASeek() {
        player.setItems(["a"])
        player.play()
        rig.run(for: 11)
        XCTAssertEqual(player.state, .ended)

        player.insert(["b"], at: 1)
        XCTAssertEqual(player.state, .ended)
        rig.run(for: 2)
        XCTAssertEqual(player.state, .ended)
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(rig.factory.calls, ["a"])

        player.seek(to: 5)
        rig.run(for: 1)
        XCTAssertEqual(player.state, .ready)
        XCTAssertEqual(player.position, 6)
    }

    // media3 ExoPlayerTest.seekToCurrentPosition_inEndedState_switchesToBufferingStateAndContinuesPlayback.
    func testASeekInAnEndedListPlaysOnIntoAnAddedItem() async {
        player.setItems(["a"])
        player.play()
        rig.run(for: 11)
        player.insert(["b"], at: 1)

        player.seek(to: player.position)
        rig.run(for: 11)
        XCTAssertEqual(player.currentIndex, 1)
        XCTAssertEqual(player.state, .ended)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 0, to: 1, reason: .auto)])
    }

    // media3 ExoPlayerTest.pauseAtEndOfMediaItems_pausesPlaybackBeforeTransitioningToTheNextItem:
    // the finished item stays current at its end, and `play()` moves on.
    func testPauseAtEndOfItemStaysAtTheEndOfTheItemUntilPlay() async {
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 1)
        player.pauseAtEndOfItem = true
        rig.run(for: 11)

        XCTAssertEqual(player.currentItem, "a")
        XCTAssertEqual(player.position, 10)
        XCTAssertFalse(player.playWhenReady)
        XCTAssertEqual(player.state, .ready)
        XCTAssertEqual(rig.output.rate, 0)
        XCTAssertEqual(rig.factory.calls, ["a", "b"], "b's arm was cleared, and nothing loaded at the end")

        player.pauseAtEndOfItem = false
        player.play()
        rig.run(for: 1)
        XCTAssertEqual(player.currentItem, "b")
        XCTAssertEqual(player.position, 1)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.kinds(events), [.playWhenReadyChanged, .itemTransition])
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 0, to: 1, reason: .auto)])
        XCTAssertEqual(PlayerRig.playWhenReadyChanges(events), [.init(value: false, reason: .endOfItem)])
    }

    // Set after decode reached b, whose arm can no longer be cleared: as media3 flushes back to the
    // current item, the player stays on a at its end, and `play()` starts b from 0.
    func testPauseAtEndOfItemSetLateStillStaysOnTheFinishedItem() async {
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 9)
        player.pauseAtEndOfItem = true
        rig.run(for: 2)

        XCTAssertEqual(player.currentItem, "a")
        XCTAssertEqual(player.position, 10)
        XCTAssertFalse(player.playWhenReady)
        XCTAssertEqual(player.state, .ready)
        XCTAssertEqual(rig.output.rate, 0)
        let written = rig.output.enqueues.count

        player.play()
        rig.run(for: 1)
        XCTAssertEqual(player.currentItem, "b")
        XCTAssertEqual(rig.firstSampleWritten(skipping: written), 1000)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 0, to: 1, reason: .auto)])
        XCTAssertEqual(PlayerRig.playWhenReadyChanges(events), [.init(value: false, reason: .endOfItem)])
    }

    func testProcessorChangesWhilePausedAtTheEndOfAnItemDoNotEndItAgain() async {
        player.setItems(["a", "b"])
        player.play()
        rig.run(for: 1)
        player.pauseAtEndOfItem = true
        rig.run(for: 11)
        XCTAssertEqual(player.position, 10)

        player.setProcessors([])
        player.processorsChanged()
        rig.run(for: 2)

        XCTAssertEqual(player.currentItem, "a")
        XCTAssertEqual(player.position, 10)
        XCTAssertEqual(player.state, .ready)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.playWhenReadyChanges(events), [.init(value: false, reason: .endOfItem)])
    }

    func testProcessorChangesAfterTheLastItemEndedKeepItEnded() {
        player.setItems(["a"])
        player.play()
        rig.run(for: 12)
        XCTAssertEqual(player.state, .ended)

        let flushes = rig.output.flushes

        player.setProcessors([])
        player.processorsChanged()
        rig.run(for: 2)

        XCTAssertEqual(player.state, .ended)
        XCTAssertEqual(rig.output.flushes, flushes)
    }

    // A seek while paused at the end stays on the item, as media3's seek within the current item does.
    func testASeekWhilePausedAtTheEndOfAnItemStaysOnIt() {
        player.setItems(["a", "b"])
        player.pauseAtEndOfItem = true
        player.play()
        rig.run(for: 11)
        XCTAssertEqual(player.position, 10)

        player.seek(to: 4)
        player.play()
        rig.run(for: 1)
        XCTAssertEqual(player.currentItem, "a")
        XCTAssertEqual(player.position, 5)
        XCTAssertEqual(player.state, .ready)
    }

    func testPauseAtEndOfItemUnderRepeatOneRepeatsOnPlay() async {
        player.setItems(["a", "b"])
        player.repeatMode = .one
        player.pauseAtEndOfItem = true
        player.play()
        rig.run(for: 11)
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(player.position, 10)

        player.play()
        rig.run(for: 1)
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(player.position, 1)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 0, to: 0, reason: .repeat)])
    }

    // Nothing is armed under pause at end, so b's source is first made by the `play()` that moves on
    // to it; its failure follows the transition into b, as a failed next's does.
    func testPauseAtEndOfItemIntoANextThatFailsToMakeReportsTheTransitionFirst() async {
        rig.factory.failing = ["b"]
        player.pauseAtEndOfItem = true
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 11)
        XCTAssertEqual(player.currentItem, "a")
        XCTAssertEqual(player.state, .ready)
        XCTAssertNil(player.error)

        player.play()
        XCTAssertEqual(player.currentItem, "b")
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(player.error?.kind, .source)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.kinds(events), [.playWhenReadyChanged, .itemTransition, .itemFailed])
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 0, to: 1, reason: .auto)])
        XCTAssertEqual(PlayerRig.failedIndices(events), [1])
    }

    // media3 ExoPlayerTest.pauseAtEndOfMediaItems_pausesPlaybackWhenEnded.
    func testPauseAtEndOfTheLastItemEnds() async {
        player.setItems(["a"])
        player.pauseAtEndOfItem = true
        player.play()
        rig.run(for: 11)

        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(player.state, .ended)
        XCTAssertFalse(player.playWhenReady)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [])
        XCTAssertEqual(PlayerRig.playWhenReadyChanges(events), [.init(value: false, reason: .endOfItem)])
    }

    // Decode has written some of b by 9 s: the insert drops it and x follows a, as media3
    // `MediaPeriodQueue.updateQueuedPeriods` drops a read-ahead period.
    func testAnInsertAfterDecodeReachedTheNextPlaysTheInsertedItemNext() async {
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 9)
        XCTAssertTrue(rig.output.enqueues.contains { $0.samples.first == 1000 }, "b is written ahead")
        player.insert(["x"], at: 1)
        rig.run(for: 2)

        XCTAssertEqual(player.currentItem, "x")
        XCTAssertEqual(player.currentIndex, 1)
        rig.run(for: 10)
        XCTAssertEqual(player.currentItem, "b")
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [
            .init(from: 0, to: 1, reason: .auto),
            .init(from: 1, to: 2, reason: .auto),
        ])
    }

    // media3 `MediaPeriodQueue.updateRepeatMode`: b, already decoded, gives way to a's repeat.
    func testARepeatChangeAfterDecodeReachedTheNextRepeatsTheCurrent() async {
        player.setItems(["a", "b"])
        player.play()
        rig.run(for: 9)
        player.repeatMode = .one
        rig.run(for: 2)

        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(player.position, 1, accuracy: 0.01)
        XCTAssertTrue(rig.output.enqueues.suffix(4).flatMap(\.samples).allSatisfy { $0 < 1000 }, "a is heard again")
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 0, to: 0, reason: .repeat)])
    }

    // The seek drops b's decoded audio; it stays armed, and the insert after replaces it.
    func testAnInsertAfterASeekBackPlaysTheInsertedItemNext() async {
        player.setItems(["a", "b"])
        player.play()
        rig.run(for: 9)
        player.seek(to: 0)
        rig.run(for: 1)
        XCTAssertEqual(rig.factory.calls, ["a", "b"], "b stays armed across the seek")
        player.insert(["x"], at: 1)
        rig.run(for: 10)

        XCTAssertEqual(player.currentItem, "x")
        XCTAssertEqual(player.currentIndex, 1)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 0, to: 1, reason: .auto)])
    }

    // An edit after the next keeps it armed, so nothing is re-fed, as media3 keeps a period that still matches.
    func testAnEditThatLeavesTheNextKeepsItWithNoFlush() async {
        player.setItems(["a", "b"])
        player.play()
        rig.run(for: 9)
        let flushes = rig.output.flushes
        player.insert(["c"], at: 2)
        player.repeatMode = .all
        rig.run(for: 2)

        XCTAssertEqual(player.currentItem, "b")
        XCTAssertEqual(rig.output.flushes, flushes)
        XCTAssertEqual(rig.factory.calls, ["a", "b", "c"], "b is opened once; c is armed once b is current")
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 0, to: 1, reason: .auto)])
    }

    // Decode had reached b: the remove drops it and c follows a.
    func testRemovingTheNextAfterDecodeReachedItPlaysTheListsNext() async {
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 9)
        player.remove(at: 1)
        rig.run(for: 2)

        XCTAssertEqual(player.currentItem, "c")
        XCTAssertEqual(player.currentIndex, 1)
        rig.run(for: 1)
        let samples = rig.output.enqueues.suffix(4).flatMap(\.samples)
        XCTAssertTrue(samples.allSatisfy { $0 >= 2000 }, "c is heard")
        XCTAssertEqual(rig.factory.calls, ["a", "b", "c"], "c is armed once")
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 0, to: 1, reason: .auto)])
    }

    // With nothing after the removed b, a's end is the end of the list.
    func testRemovingTheLastItemAfterDecodeReachedItEnds() async {
        player.setItems(["a", "b"])
        player.play()
        rig.run(for: 9)
        player.remove(at: 1)
        rig.run(for: 2)

        XCTAssertEqual(player.currentItem, "a")
        XCTAssertEqual(player.state, .ended)
        let written = rig.output.enqueues.count
        rig.run(for: 2)
        XCTAssertEqual(player.state, .ended)
        XCTAssertEqual(rig.output.enqueues.count, written, "b is not played on")
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [])
    }

    // c is not armed, as pause at end was set after b was removed: a's end pauses there, and `play()`
    // moves on to c.
    func testRemovingTheNextUnderPauseAtEndPausesAtTheEndOfTheItem() async {
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 9)
        player.remove(at: 1)
        player.pauseAtEndOfItem = true
        rig.run(for: 2)

        XCTAssertEqual(player.currentItem, "a")
        XCTAssertEqual(player.position, 10)
        XCTAssertFalse(player.playWhenReady)
        XCTAssertEqual(player.state, .ready)
        XCTAssertEqual(rig.output.rate, 0)

        player.play()
        rig.run(for: 1)
        XCTAssertEqual(player.currentItem, "c")
        XCTAssertEqual(player.currentIndex, 1)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 0, to: 1, reason: .auto)])
        XCTAssertEqual(PlayerRig.playWhenReadyChanges(events), [.init(value: false, reason: .endOfItem)])
    }

    // c is not armed, as its source failed to make: a's end reports it.
    func testACrossingIntoARemovedNextReportsTheListsFailedNext() async {
        rig.factory.failing = ["c"]
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 9)
        player.remove(at: 1)
        rig.run(for: 2)

        XCTAssertEqual(player.currentItem, "c")
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(player.error?.kind, .source)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.kinds(events), [.itemTransition, .itemFailed])
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 0, to: 1, reason: .auto)])
        XCTAssertEqual(PlayerRig.failedIndices(events), [1])
    }

    // media3 ExoPlayerTest.removeMediaItem_withRepeatModeOne_endsPlaybackAndStopsLoading.
    func testRemovingTheCurrentUnderRepeatOneEnds() async {
        player.setItems(["a", "b"])
        player.repeatMode = .one
        player.play()
        rig.run(for: 1)

        player.remove(at: 0)
        XCTAssertEqual(player.currentItem, "b")
        XCTAssertEqual(player.state, .ended)
        rig.run(for: 1)
        XCTAssertEqual(player.state, .ended)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 0, to: 0, reason: .seek)])
    }

    // Under `.all` the first item takes the removed last item's place, so playback goes on.
    func testRemovingTheCurrentLastItemUnderRepeatAllPlaysTheFirst() async {
        player.setItems(["a", "b", "c"], startIndex: 2)
        player.repeatMode = .all
        player.play()
        rig.run(for: 1)
        let written = rig.output.enqueues.count

        player.remove(at: 2)
        XCTAssertEqual(player.currentIndex, 0)
        rig.pump()
        XCTAssertEqual(rig.firstSampleWritten(skipping: written), 0)
        XCTAssertEqual(player.state, .ready)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 2, to: 0, reason: .seek)])
    }
}
