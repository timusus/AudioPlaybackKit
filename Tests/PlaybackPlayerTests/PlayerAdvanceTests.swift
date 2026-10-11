import Foundation
import PlaybackRender
import XCTest
@testable import PlaybackPlayer

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

    // ADR-0019 departs from media3, which pauses at the end of the item itself: the next is current,
    // paused at 0, so `play()` plays it.
    func testPauseAtEndOfItemLandsPausedAtTheStartOfTheNext() async {
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 1)
        player.pauseAtEndOfItem = true
        rig.run(for: 11)

        XCTAssertEqual(player.currentItem, "b")
        XCTAssertEqual(player.position, 0)
        XCTAssertFalse(player.playWhenReady)
        XCTAssertEqual(player.state, .ready)
        XCTAssertEqual(rig.output.rate, 0)
        XCTAssertEqual(rig.factory.calls, ["a", "b", "b"], "b's arm was cleared, and b loaded at the end")

        player.pauseAtEndOfItem = false
        player.play()
        rig.run(for: 1)
        XCTAssertEqual(player.currentItem, "b")
        XCTAssertEqual(player.position, 1)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 0, to: 1, reason: .auto)])
        XCTAssertEqual(PlayerRig.playWhenReadyChanges(events), [.init(value: false, reason: .endOfItem)])
    }

    // Set after decode reached b, whose arm can no longer be cleared: b is paused at 0 once it is heard.
    func testPauseAtEndOfItemSetLatePausesTheNextAtItsStart() async {
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 9)
        player.pauseAtEndOfItem = true
        rig.run(for: 2)

        XCTAssertEqual(player.currentItem, "b")
        XCTAssertEqual(player.position, 0)
        XCTAssertFalse(player.playWhenReady)
        XCTAssertEqual(player.state, .ready)
        XCTAssertEqual(rig.output.rate, 0)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 0, to: 1, reason: .auto)])
        XCTAssertEqual(PlayerRig.playWhenReadyChanges(events), [.init(value: false, reason: .endOfItem)])
    }

    // Nothing is armed under pause at end, so b's source is first made at a's end; its failure
    // follows the transition into b, as a failed next's does.
    func testPauseAtEndOfItemIntoANextThatFailsToMakeReportsTheTransitionFirst() async {
        rig.factory.failing = ["b"]
        player.pauseAtEndOfItem = true
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 11)

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

    // An insert after decode reached b arms x behind b, so b is still heard: the player follows it.
    func testACrossingIntoANextArmedBeforeAnEditIsReportedByItsIndex() async {
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 9)
        player.insert(["x"], at: 1)
        rig.run(for: 2)

        XCTAssertEqual(player.currentItem, "b")
        XCTAssertEqual(player.currentIndex, 2)
        rig.run(for: 10)
        XCTAssertEqual(player.currentItem, "c")
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [
            .init(from: 0, to: 2, reason: .auto),
            .init(from: 2, to: 3, reason: .auto),
        ])
    }

    // b was removed after decode reached it, so the transport still joins into it; the player moves
    // on to the list's next instead of reporting an item it no longer has.
    func testACrossingIntoARemovedNextPlaysTheListsNext() async {
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
        XCTAssertEqual(rig.factory.calls, ["a", "b", "c"], "the transport took the seek to c's armed key")
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 0, to: 1, reason: .auto)])
    }

    // With nothing after the removed b, a's end is the end of the list.
    func testACrossingIntoARemovedLastItemEnds() async {
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

    // c is not armed, as pause at end was set after b was removed: a's end pauses at c's start.
    func testACrossingIntoARemovedNextUnderPauseAtEndPausesAtTheListsNext() async {
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 9)
        player.remove(at: 1)
        player.pauseAtEndOfItem = true
        rig.run(for: 2)

        XCTAssertEqual(player.currentItem, "c")
        XCTAssertEqual(player.position, 0)
        XCTAssertFalse(player.playWhenReady)
        XCTAssertEqual(player.state, .ready)
        XCTAssertEqual(rig.output.rate, 0)
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
