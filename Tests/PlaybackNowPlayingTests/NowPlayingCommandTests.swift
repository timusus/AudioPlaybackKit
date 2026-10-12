import MediaPlayer
import PlaybackPlayer
import XCTest
@testable import PlaybackNowPlaying

/// Which remote commands are enabled in which state, after media3's available commands, and that each
/// one reaches the player.
@MainActor
final class NowPlayingCommandTests: XCTestCase {
    private var rig: NowPlayingRig!

    override func setUp() async throws {
        rig = NowPlayingRig()
    }

    override func tearDown() async throws {
        rig = nil
    }

    private var enabled: Set<RemoteCommand> { rig.commands.enabled }

    /// Replaces the rig with one whose session drives a `PolicyPlayer` over the player.
    @discardableResult
    private func policyRig(live: Set<String> = [], intervals: SkipIntervals? = nil) -> PolicyPlayer {
        var policy: PolicyPlayer!
        rig = NowPlayingRig(live: live) {
            policy = PolicyPlayer($0, intervals: intervals)
            return policy
        }
        return policy
    }

    /// The items, played until the current one has opened, then paused.
    private func opened(_ items: [String] = ["a", "b", "c"], at index: Int = 0) async {
        rig.player.setItems(items, startIndex: index)
        rig.player.play()
        await rig.run(for: 1)
        rig.player.pause()
        await rig.settle()
    }

    // MARK: Availability

    // media3 ExoPlayerTest.isCommandAvailable_isTrueForAvailableCommands: play-pause is always
    // available, seeking in the item only once it is known to be seekable.
    func testPlayPauseIsAvailableWithNoItemAndAnswersNoActionableItem() async {
        await rig.settle()

        XCTAssertEqual(enabled, [.play, .pause, .togglePlayPause])
        XCTAssertEqual(rig.commands.press(.play), .noActionableNowPlayingItem)
        XCTAssertFalse(rig.player.playWhenReady)
    }

    func testSeekingIsUnavailableUntilTheItemOpens() async {
        rig.player.setItems(["a"])
        await rig.settle()
        XCTAssertFalse(enabled.contains(.changePlaybackPosition))

        rig.player.play()
        await rig.run(for: 1)
        XCTAssertTrue(enabled.contains(.changePlaybackPosition))
    }

    // media3 ExoPlayerTest.isCommandAvailable_duringUnseekableItem_isFalseForSeekInCurrentCommands
    func testSeekingIsUnavailableForALiveItem() async {
        policyRig(live: ["a"], intervals: SkipIntervals(forward: 15, backward: 15))
        await opened(["a"])

        XCTAssertTrue(rig.player.isLive)
        XCTAssertFalse(enabled.contains(.changePlaybackPosition))
        XCTAssertFalse(enabled.contains(.skipForward))
        XCTAssertFalse(enabled.contains(.skipBackward))
    }

    // ADR-0022, media3 COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM follows Window.isSeekable, not its duration.
    func testAScrubOnASeekableItemOfUnknownLengthSeeks() async {
        rig = NowPlayingRig(unknownLength: ["a"])
        await opened(["a"])

        XCTAssertFalse(rig.player.isLive)
        XCTAssertTrue(enabled.contains(.changePlaybackPosition))
        XCTAssertEqual(rig.commands.press(.changePlaybackPosition, .position(6)), .success)
        XCTAssertEqual(rig.player.position, 6)
    }

    // ADR-0019: skip intervals add skipForward and skipBackward; next and previous follow availableCommands.
    func testAPlayerEnablesNextAndPreviousAndNoSkips() async {
        await opened(at: 1)

        XCTAssertEqual(enabled, [.play, .pause, .togglePlayPause, .nextTrack, .previousTrack, .changePlaybackPosition])
        XCTAssertNil(rig.commands.intervals)
    }

    func testSkipIntervalsEnableSkipsWithTheirIntervalsAlongsideTracks() async {
        policyRig(intervals: SkipIntervals(forward: 15, backward: 30))
        await opened(at: 1)

        XCTAssertEqual(enabled, [.play, .pause, .togglePlayPause, .nextTrack, .previousTrack, .skipForward, .skipBackward, .changePlaybackPosition])
        XCTAssertEqual(rig.commands.intervals?.forward, 15)
        XCTAssertEqual(rig.commands.intervals?.backward, 30)
    }

    // A steering-wheel or headphone press of next or previous reaches the player while skip buttons show.
    func testNextAndPreviousWorkWithSkipIntervals() async {
        _ = policyRig(intervals: SkipIntervals(forward: 15, backward: 30))
        await opened(at: 1)

        XCTAssertEqual(rig.commands.press(.nextTrack), .success)
        XCTAssertEqual(rig.player.currentIndex, 2)
        XCTAssertEqual(rig.commands.press(.previousTrack), .success)
        XCTAssertEqual(rig.player.currentIndex, 1)
    }

    func testSkipIntervalsWithoutTrackCommandsLeaveNextAndPreviousUnregistered() async {
        let policy = policyRig(intervals: SkipIntervals(forward: 15, backward: 30))
        policy.removed = [.seekToNext, .seekToPrevious]
        await opened(at: 1)

        XCTAssertEqual(enabled, [.play, .pause, .togglePlayPause, .skipForward, .skipBackward, .changePlaybackPosition])
        XCTAssertNil(rig.commands.press(.nextTrack))
        XCTAssertNil(rig.commands.press(.previousTrack))
    }

    func testChangingTheSkipIntervalsAddsAndRemovesTheSkips() async {
        let policy = policyRig()
        await opened(at: 1)

        policy.intervals = SkipIntervals(forward: 10, backward: 10)
        await rig.settle()
        XCTAssertTrue(enabled.isSuperset(of: [.skipForward, .skipBackward, .nextTrack, .previousTrack]))
        XCTAssertEqual(rig.commands.intervals?.forward, 10)

        policy.intervals = nil
        await rig.settle()
        XCTAssertTrue(enabled.isSuperset(of: [.nextTrack, .previousTrack]))
        XCTAssertTrue(enabled.isDisjoint(with: [.skipForward, .skipBackward]))
        XCTAssertNil(rig.commands.intervals)
    }

    // media3 ExoPlayerTest.seekTo_nextWindow_notifiesAvailableCommandsChanged,
    // seekTo_previousWindow_notifiesAvailableCommandsChanged
    func testNextFollowsTheCurrentIndex() async {
        await opened()
        XCTAssertTrue(enabled.contains(.nextTrack))

        rig.player.seek(to: 0, itemAt: 1)
        await rig.settle()
        XCTAssertTrue(enabled.contains(.nextTrack))

        rig.player.seek(to: 0, itemAt: 2)
        await rig.settle()
        XCTAssertFalse(enabled.contains(.nextTrack))
    }

    // media3 COMMAND_SEEK_TO_PREVIOUS, which the lock screen's previous button is: available on any
    // item but an unseekable live one with nothing before it.
    func testPreviousIsAvailableOnTheFirstItem() async {
        rig.player.setItems(["a", "b"])
        await rig.settle()

        XCTAssertTrue(enabled.contains(.previousTrack))
    }

    // media3 ExoPlayerTest.isCommandAvailable_duringUnseekableLiveItem_isFalseForSeekToPrevious,
    // isCommandAvailable_duringUnseekableLiveItemWithPreviousWindow_isTrueForSeekToPrevious
    func testPreviousOnALiveItemNeedsAPreviousItem() async {
        rig = NowPlayingRig(live: ["a", "b"])
        await opened(["a", "b"])
        XCTAssertFalse(enabled.contains(.previousTrack))

        rig.player.seek(to: 0, itemAt: 1)
        rig.player.play()
        await rig.run(for: 1)
        XCTAssertTrue(rig.player.isLive)
        XCTAssertTrue(enabled.contains(.previousTrack))
    }

    // media3 ExoPlayerTest.automaticWindowTransition_notifiesAvailableCommandsChanged
    func testAnAutomaticAdvanceToTheLastItemDisablesNext() async {
        rig.player.setItems(["a", "b"])
        rig.player.play()
        await rig.run(for: 11)

        XCTAssertEqual(rig.player.currentIndex, 1)
        XCTAssertFalse(enabled.contains(.nextTrack))
        XCTAssertTrue(enabled.contains(.previousTrack))
    }

    // media3 ExoPlayerTest.addMediaSource_atTheEnd_notifiesAvailableCommandsChanged,
    // addMediaSource_atTheStart_notifiesAvailableCommandsChanged,
    // removeMediaItem_atTheEnd_notifiesAvailableCommandsChanged,
    // removeMediaItem_atTheStart_notifiesAvailableCommandsChanged
    func testEditsAroundTheCurrentItemUpdateNext() async {
        await opened(["a"])
        XCTAssertFalse(enabled.contains(.nextTrack))

        rig.player.insert(["b"], at: 1)
        await rig.settle()
        XCTAssertTrue(enabled.contains(.nextTrack))

        rig.player.insert(["x"], at: 0)
        await rig.settle()
        XCTAssertTrue(enabled.contains(.nextTrack))

        rig.player.remove(at: 2)
        await rig.settle()
        XCTAssertFalse(enabled.contains(.nextTrack))
    }

    // media3 ExoPlayerTest.removeMediaItem_current_notifiesAvailableCommandsChanged
    func testRemovingTheCurrentItemUpdatesNext() async {
        await opened(["a", "b"])

        rig.player.remove(at: 0)
        await rig.settle()

        XCTAssertEqual(enabled.intersection([.nextTrack, .previousTrack]), [.previousTrack])
    }

    // media3 ExoPlayerTest.setRepeatMode_all_notifiesAvailableCommandsChanged,
    // setRepeatMode_one_doesNotNotifyAvailableCommandsChanged
    func testRepeatAllEnablesNextOnTheLastItemAndRepeatOneDoesNot() async {
        await opened(["a", "b"], at: 1)

        rig.player.repeatMode = .one
        await rig.settle()
        XCTAssertFalse(enabled.contains(.nextTrack))

        rig.player.repeatMode = .all
        await rig.settle()
        XCTAssertTrue(enabled.contains(.nextTrack))
    }

    func testChangePlaybackRateIsEnabledOnlyWithSupportedRates() async {
        await opened()
        XCTAssertFalse(enabled.contains(.changePlaybackRate))
        XCTAssertNil(rig.commands.rates)

        rig = NowPlayingRig(supportedRates: [1, 1.5, 2])
        await opened()
        XCTAssertTrue(enabled.contains(.changePlaybackRate))
        XCTAssertEqual(rig.commands.rates, [1, 1.5, 2])
    }

    // MARK: Routing

    // media3 MediaSessionPlayerTest.play, pause
    func testPlayAndPauseSetPlayWhenReady() async {
        await opened()

        XCTAssertEqual(rig.commands.press(.play), .success)
        XCTAssertTrue(rig.player.playWhenReady)
        XCTAssertEqual(rig.commands.press(.pause), .success)
        XCTAssertFalse(rig.player.playWhenReady)
    }

    // media3 MediaSessionPlayerTest.executeCommandButtonAction_playPauseWithoutParam_togglesPlayWhenReady
    func testTogglePausesWhilePlayingAndPlaysWhilePaused() async {
        await opened()

        rig.commands.press(.togglePlayPause)
        XCTAssertTrue(rig.player.playWhenReady)
        rig.commands.press(.togglePlayPause)
        XCTAssertFalse(rig.player.playWhenReady)
    }

    // media3 Util.shouldShowPlayButton: ended shows play, and play restarts the item.
    func testTogglePlaysOnEndedFromTheStart() async {
        rig.player.setItems(["a"])
        rig.player.play()
        await rig.run(for: 11)
        XCTAssertEqual(rig.player.state, .ended)
        XCTAssertTrue(rig.player.playWhenReady)

        rig.commands.press(.togglePlayPause)
        await rig.run(for: 1)

        XCTAssertTrue(rig.player.isPlaying)
        XCTAssertLessThan(rig.player.position, 2)
    }

    // media3 MediaSession.Builder.setPlayIfSuppressed (default true): suppressed shows play.
    func testTogglePlaysWhileSuppressed() async {
        rig.player.setItems(["a"])
        rig.player.play()
        await rig.run(for: 1)
        rig.base.session.interruptionBegan()
        XCTAssertEqual(rig.player.suppression, .interruption)

        rig.commands.press(.togglePlayPause)
        await rig.run(for: 1)

        XCTAssertTrue(rig.player.playWhenReady)
        XCTAssertTrue(rig.player.isPlaying)
    }

    // media3 MediaSessionPlayerTest.seekToNextMediaItem, seekToPreviousMediaItem
    func testNextAndPreviousSkip() async {
        await opened(at: 1)

        XCTAssertEqual(rig.commands.press(.nextTrack), .success)
        XCTAssertEqual(rig.player.currentIndex, 2)
        await rig.settle()
        XCTAssertEqual(rig.commands.press(.previousTrack), .success)
        XCTAssertEqual(rig.player.currentIndex, 1)
    }

    // media3 Player.seekToPrevious with no previous item seeks the current one to 0; with no 3 s
    // threshold (ADR-0019), a previous item is always where it goes.
    func testPreviousOnTheFirstItemRestartsIt() async {
        await opened()
        XCTAssertGreaterThan(rig.player.position, 0)

        XCTAssertEqual(rig.commands.press(.previousTrack), .success)

        XCTAssertEqual(rig.player.currentIndex, 0)
        XCTAssertEqual(rig.player.position, 0)
    }

    // media3 MediaSessionPlayerTest.seekForward, seekBack
    func testSkipsSeekByTheirInterval() async {
        policyRig(intervals: SkipIntervals(forward: 3, backward: 2))
        await opened()
        rig.player.seek(to: 1)

        XCTAssertEqual(rig.commands.press(.skipForward, .interval(3)), .success)
        XCTAssertEqual(rig.player.position, 4)
        XCTAssertEqual(rig.commands.press(.skipBackward, .interval(2)), .success)
        XCTAssertEqual(rig.player.position, 2)
    }

    // media3 MediaSessionPlayerTest.seekTo
    func testChangePlaybackPositionSeeks() async {
        await opened()

        XCTAssertEqual(rig.commands.press(.changePlaybackPosition, .position(6)), .success)

        XCTAssertEqual(rig.player.position, 6)
    }

    // media3 MediaSessionPlayerTest.setPlaybackSpeed
    func testChangePlaybackRateSetsTheRate() async {
        rig = NowPlayingRig(supportedRates: [1, 1.5])
        await opened()

        XCTAssertEqual(rig.commands.press(.changePlaybackRate, .rate(1.5)), .success)

        XCTAssertEqual(rig.player.rate, 1.5)
    }

    // media3 MediaSessionPlayerTest.sendCustomCommand_malformedPredefinedCommand_doesNotCrash
    func testAMalformedEventFails() async {
        await opened()

        XCTAssertEqual(rig.commands.press(.changePlaybackPosition, .plain), .commandFailed)
        XCTAssertEqual(rig.player.position, 1, accuracy: 0.5)
    }

    // MARK: Through a wrapper (media3 ForwardingPlayer)

    // As a media3 session offers a controller only the player's available commands.
    func testAWrapperThatRemovesNextDisablesItAndKeepsTheRest() async {
        let policy = policyRig()
        policy.removed = .seekToNext
        await opened(at: 1)

        XCTAssertEqual(enabled, [.play, .pause, .togglePlayPause, .previousTrack, .changePlaybackPosition])
        XCTAssertNil(rig.commands.press(.nextTrack))
        XCTAssertEqual(rig.player.currentIndex, 1)
    }

    func testNextGoesThroughTheWrappersPolicy() async {
        let policy = policyRig()
        policy.vetoesNext = true
        await opened(at: 1)

        XCTAssertEqual(rig.commands.press(.nextTrack), .success)

        XCTAssertEqual(policy.vetoedNexts, 1)
        XCTAssertEqual(rig.player.currentIndex, 1)
    }

    func testTheRateCommandGoesThroughTheWrapper() async {
        var policy: PolicyPlayer!
        rig = NowPlayingRig(supportedRates: [1, 1.5]) {
            policy = PolicyPlayer($0)
            return policy
        }
        await opened()

        XCTAssertEqual(rig.commands.press(.changePlaybackRate, .rate(1.5)), .success)

        XCTAssertEqual(policy.savedRates, [1.5])
        XCTAssertEqual(rig.player.rate, 1.5)
    }

    func testSkipIntervalsArePerItem() async {
        let policy = policyRig()
        policy.itemIntervals = ["a": SkipIntervals(forward: 30, backward: 30)]
        await opened(["a", "b", "c"])

        XCTAssertTrue(enabled.isSuperset(of: [.skipForward, .skipBackward]))
        XCTAssertTrue(enabled.isSuperset(of: [.nextTrack, .previousTrack]))
        XCTAssertEqual(rig.commands.intervals?.forward, 30)
        XCTAssertEqual(rig.commands.intervals?.backward, 30)
        XCTAssertEqual(rig.commands.press(.skipBackward, .interval(30)), .success)
        XCTAssertEqual(rig.player.position, 0)

        rig.player.seek(to: 0, itemAt: 1)
        await rig.settle()
        XCTAssertTrue(enabled.isSuperset(of: [.nextTrack, .previousTrack]))
        XCTAssertTrue(enabled.isDisjoint(with: [.skipForward, .skipBackward]))
        XCTAssertNil(rig.commands.intervals)
        XCTAssertEqual(rig.commands.press(.nextTrack), .success)
        XCTAssertEqual(rig.player.currentIndex, 2)
    }

    func testCommandsTheWrapperRemovesMidItemAreDisabledAndRefusedAtOnce() async {
        let policy = policyRig()
        await opened()
        XCTAssertTrue(enabled.contains(.changePlaybackPosition))

        policy.removed = .seekInCurrentItem
        XCTAssertEqual(rig.commands.press(.changePlaybackPosition, .position(6)), .commandFailed, "refused before the refresh")
        XCTAssertEqual(rig.player.position, 1, accuracy: 0.5)
        await rig.settle()
        XCTAssertFalse(enabled.contains(.changePlaybackPosition))

        policy.removed = []
        await rig.settle()
        XCTAssertEqual(rig.commands.press(.changePlaybackPosition, .position(6)), .success)
        XCTAssertEqual(rig.player.position, 6)
    }

    func testReleaseDisablesEveryCommandAndClearsTheInfo() async {
        await opened()

        rig.session.release()
        rig.player.seek(to: 5)
        await rig.settle()

        XCTAssertEqual(enabled, [])
        XCTAssertNil(rig.info.nowPlayingInfo)
        XCTAssertEqual(rig.info.playbackState, .stopped)
    }

    func testDroppingTheSessionReleasesIt() async {
        await opened()
        XCTAssertNotEqual(enabled, [])

        rig.dropSession()

        XCTAssertEqual(enabled, [])
        XCTAssertNil(rig.info.nowPlayingInfo)
        XCTAssertEqual(rig.info.playbackState, .stopped)
    }

    func testReleaseClearsTheRatesAndSkipIntervalsItSet() async {
        rig = NowPlayingRig(supportedRates: [1, 2]) { PolicyPlayer($0, intervals: SkipIntervals(forward: 15, backward: 30)) }
        await opened()

        rig.session.release()

        XCTAssertEqual(rig.commands.rates, [])
        XCTAssertNil(rig.commands.intervals)
    }
}
