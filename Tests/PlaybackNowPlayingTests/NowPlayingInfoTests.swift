import MediaPlayer
import PlaybackPlayer
import XCTest
@testable import PlaybackNowPlaying

/// What reaches `MPNowPlayingInfoCenter`, and when: metadata on an item change, elapsed time and rate
/// on a seek, a pause or play, a rate change or an item change, and nothing on a position pump, since
/// the system extrapolates elapsed time from the rate.
@MainActor
final class NowPlayingInfoTests: XCTestCase {
    private var rig: NowPlayingRig!

    override func setUp() async throws {
        rig = NowPlayingRig()
    }

    override func tearDown() async throws {
        rig = nil
    }

    private var elapsed: Double? { rig.info[MPNowPlayingInfoPropertyElapsedPlaybackTime] }
    private var rate: Double? { rig.info[MPNowPlayingInfoPropertyPlaybackRate] }
    private var defaultRate: Double? { rig.info[MPNowPlayingInfoPropertyDefaultPlaybackRate] }
    private var title: String? { rig.info[MPMediaItemPropertyTitle] }
    private var duration: Double? { rig.info[MPMediaItemPropertyPlaybackDuration] }

    private func playing(_ items: [String] = ["a", "b"], for seconds: TimeInterval = 2) async {
        rig.player.setItems(items)
        rig.player.play()
        await rig.run(for: seconds)
    }

    // media3 MediaControllerTest.getMediaMetadata, getCurrentPosition_whenPlaying_advances
    func testAnItemPublishesItsMetadataDurationElapsedAndRate() async {
        await playing()

        XCTAssertEqual(title, "A")
        XCTAssertEqual(rig.info[MPMediaItemPropertyArtist], "Artist a")
        XCTAssertEqual(rig.info[MPMediaItemPropertyAlbumTitle], "Album")
        XCTAssertEqual(duration, 10)
        XCTAssertEqual(elapsed, rig.player.position)
        XCTAssertEqual(rate, 1)
        XCTAssertEqual(defaultRate, 1)
        XCTAssertEqual(rig.info[MPNowPlayingInfoPropertyIsLiveStream], false)
        XCTAssertEqual(rig.info.playbackState, .playing)
    }

    func testTheAppsDurationIsShownUntilThePlayerKnowsItsOwn() async {
        rig.player.setItems(["a"])
        await rig.settle()
        XCTAssertEqual(title, "A")
        XCTAssertEqual(duration, 99)

        rig.player.play()
        await rig.run(for: 1)
        XCTAssertEqual(duration, 10)
    }

    func testPositionPumpsWriteNothing() async {
        await playing()
        let writes = rig.info.writes

        await rig.run(for: 4)

        XCTAssertGreaterThan(rig.player.position, 5)
        XCTAssertEqual(rig.info.writes, writes)
    }

    func testASeekWritesTheNewElapsedTime() async {
        await playing()

        rig.player.seek(to: 7)
        await rig.settle()

        // Buffering until the next decode, so the system must not extrapolate yet.
        XCTAssertEqual(elapsed, 7)
        XCTAssertEqual(rate, 0)
        XCTAssertEqual(rig.info.playbackState, .playing)

        await rig.run(for: 1)
        XCTAssertEqual(rate, 1)
        XCTAssertEqual(elapsed, rig.player.position)
    }

    func testASmallSeekBackWhilePlayingWritesTheNewElapsedTime() async {
        await playing(for: 4)
        XCTAssertGreaterThan(rig.player.position, 3.5)

        rig.player.seek(to: 3.5)
        await rig.settle()

        XCTAssertEqual(elapsed, 3.5)
    }

    func testASmallForwardSeekWhilePlayingWritesTheNewElapsedTime() async {
        await playing()
        XCTAssertEqual(rig.player.position, 2)

        rig.player.seek(by: 0.5)
        await rig.settle()

        XCTAssertEqual(elapsed, 2.5)
    }

    // The seek's buffering is over before the session reads the player, so only the jump tells it.
    func testASeekThatNeverBuffersWritesTheNewElapsedTime() async {
        await playing()

        rig.player.seek(by: 0.5)
        rig.base.pump()
        await rig.settle()

        XCTAssertEqual(rig.player.state, .ready)
        XCTAssertEqual(rate, 1)
        XCTAssertEqual(elapsed, 2.5)
    }

    func testASmallSeekBackWhilePausedWritesTheNewElapsedTime() async {
        await playing()
        rig.player.pause()
        await rig.settle()
        let paused = rig.player.position

        rig.player.seek(by: -0.5)
        await rig.settle()

        XCTAssertEqual(elapsed, paused - 0.5)
    }

    // media3 MediaControllerTest.getCurrentPosition_afterPause_returnsCorrectPosition,
    // getCurrentPosition_whenNotPlaying_doesNotAdvance
    func testPauseWritesTheElapsedTimeAndRateZero() async {
        await playing()

        rig.player.pause()
        await rig.settle()

        XCTAssertEqual(elapsed, rig.player.position)
        XCTAssertEqual(rate, 0)
        XCTAssertEqual(defaultRate, 1)
        XCTAssertEqual(rig.info.playbackState, .paused)
    }

    func testPlayWritesTheRate() async {
        rig.player.setItems(["a"])
        await rig.settle()
        XCTAssertEqual(rate, 0)

        rig.player.play()
        await rig.run(for: 1)

        XCTAssertEqual(rate, 1)
        XCTAssertEqual(elapsed, rig.player.position)
        XCTAssertEqual(rig.info.playbackState, .playing)
    }

    // ADR-0027, media3 MediaSessionLegacyStub: speed is 0 until playing, while the button shows pause.
    func testRateStaysZeroWhileBufferingWithPlayIntentThenFollowsTheRate() async {
        rig.player.setItems(["a"])
        rig.player.rate = 1.5
        rig.player.play()
        await rig.settle()

        XCTAssertTrue(rig.player.playWhenReady)
        XCTAssertFalse(rig.player.isPlaying)
        XCTAssertEqual(rate, 0)
        XCTAssertEqual(defaultRate, 1.5)
        XCTAssertEqual(rig.info.playbackState, .playing)

        await rig.run(for: 1)

        XCTAssertEqual(rate, 1.5)
    }

    // On an iPhone a fresh renderer's clock started 0.2 s after the play, so the elapsed time
    // written at the play ran ahead of what was heard for as long as it played.
    func testAPlayHeardLateRewritesTheElapsedTimeOnceHeard() async {
        await playing()
        rig.player.pause()
        await rig.settle()
        rig.player.play()
        await rig.settle()
        XCTAssertEqual(rate, 1)
        XCTAssertEqual(elapsed, 2)

        rig.wall += 0.5
        await rig.run(for: 1)

        XCTAssertEqual(rig.player.position, 3)
        XCTAssertEqual(elapsed, 3)
        XCTAssertEqual(rate, 1)
    }

    // The output starts late, so any refresh during the hold (here a wrapper's command set changing)
    // would find the system's extrapolation ahead of the held position and rewrite.
    func testAHeldPositionWritesNothingUntilItMoves() async {
        var policy: PolicyPlayer!
        rig = NowPlayingRig {
            policy = PolicyPlayer($0)
            return policy
        }
        await playing()
        rig.player.pause()
        await rig.settle()
        rig.player.play()
        await rig.settle()
        let writes = rig.info.writes

        for tick in 0..<5 {
            rig.wall += 0.1
            policy.removed = tick.isMultiple(of: 2) ? .seekToNext : []
            await rig.settle()
        }

        XCTAssertEqual(rig.player.position, 2)
        XCTAssertEqual(rig.info.writes, writes)

        rig.wall += 0.5
        await rig.run(for: 1)

        XCTAssertEqual(rig.info.writes, writes + 1)
        XCTAssertEqual(elapsed, 3)
    }

    func testADriftUnderTheThresholdWritesNothing() async {
        await playing()
        let writes = rig.info.writes

        rig.wall += 0.04
        await rig.run(for: 1)

        XCTAssertEqual(rig.info.writes, writes)
    }

    func testARateChangeWritesTheRateAndDefaultRate() async {
        await playing()

        rig.player.rate = 1.5
        await rig.settle()

        XCTAssertEqual(rate, 1.5)
        XCTAssertEqual(defaultRate, 1.5)
        XCTAssertEqual(elapsed, rig.player.position)
    }

    func testARateChangeWhilePausedWritesTheDefaultRateOnly() async {
        rig.player.setItems(["a"])
        await rig.settle()

        rig.player.rate = 2
        await rig.settle()

        XCTAssertEqual(rate, 0)
        XCTAssertEqual(defaultRate, 2)
    }

    func testSkippingToAnotherItemWritesItFromZero() async {
        await playing()

        rig.player.skipToNext()
        await rig.settle()

        XCTAssertEqual(title, "B")
        XCTAssertEqual(elapsed, 0)
        XCTAssertEqual(duration, 99)
    }

    func testAnAutomaticAdvanceWritesTheNextItem() async {
        await playing(for: 9)
        XCTAssertEqual(title, "A")

        await rig.run(for: 2)

        XCTAssertEqual(rig.player.currentIndex, 1)
        XCTAssertEqual(title, "B")
        XCTAssertEqual(elapsed, rig.player.position)
        XCTAssertLessThan(rig.player.position, 2)
    }

    func testARepeatOfTheSameItemWritesElapsedFromTheStart() async {
        rig.player.repeatMode = .one
        await playing(["a"], for: 9)
        let writes = rig.info.writes

        await rig.run(for: 2)

        XCTAssertEqual(title, "A")
        XCTAssertEqual(rig.info.writes, writes + 1)
        XCTAssertEqual(elapsed, rig.player.position)
        XCTAssertLessThan(rig.player.position, 2)
    }

    func testAnInterruptionShowsPausedWithRateZero() async {
        await playing()

        rig.base.session.interruptionBegan()
        await rig.settle()

        XCTAssertEqual(rate, 0)
        XCTAssertEqual(elapsed, rig.player.position)
        XCTAssertEqual(rig.info.playbackState, .paused)
    }

    func testEmptyingTheListClearsTheInfo() async {
        await playing()

        rig.player.removeAll()
        await rig.settle()

        XCTAssertNil(rig.info.nowPlayingInfo)
        XCTAssertEqual(rig.info.playbackState, .stopped)
    }

    func testALiveItemIsMarkedLiveWithNoDuration() async {
        rig = NowPlayingRig(live: ["a"])
        await playing(["a"])

        XCTAssertEqual(rig.info[MPNowPlayingInfoPropertyIsLiveStream], true)
        XCTAssertNil(duration)
    }

    // ADR-0022: no known length is not live, so the metadata's duration stands in and elapsed time runs.
    func testASeekableItemOfUnknownLengthIsNotLiveAndShowsTheMetadataDuration() async {
        rig = NowPlayingRig(unknownLength: ["a"])
        await playing(["a"])
        rig.player.seek(to: 5)
        await rig.settle()

        XCTAssertEqual(rig.info[MPNowPlayingInfoPropertyIsLiveStream], false)
        XCTAssertEqual(duration, 99)
        XCTAssertEqual(elapsed, 5)
    }

    func testTheCurrentItemsArtworkIsPublished() async {
        rig.player.setItems(["a", "b"])
        await rig.settle()
        await rig.session.artworkLoad?.value

        let artwork: MPMediaItemArtwork? = rig.info[MPMediaItemPropertyArtwork]
        XCTAssertNotNil(artwork)
        XCTAssertTrue(artwork === rig.artworks["a"])
    }

    func testArtworkThatArrivesAfterTheItemChangedIsDropped() async {
        rig.heldArtwork = ["a"]
        rig.player.setItems(["a", "b"])
        await rig.settle()
        let loadA = rig.session.artworkLoad

        rig.player.skipToNext()
        await rig.settle()
        await rig.session.artworkLoad?.value
        rig.deliverArtwork(for: "a")
        await loadA?.value

        let artwork: MPMediaItemArtwork? = rig.info[MPMediaItemPropertyArtwork]
        XCTAssertNotNil(rig.artworks["a"])
        XCTAssertTrue(artwork === rig.artworks["b"])
    }

    func testArtworkFromAnEarlierVisitToTheSameItemIsDropped() async {
        rig.heldArtwork = ["a"]
        rig.player.setItems(["a", "b"])
        await rig.settle()
        let firstLoad = rig.session.artworkLoad
        rig.player.skipToNext()
        await rig.settle()
        await rig.session.artworkLoad?.value
        rig.player.skipToPrevious()
        await rig.settle()
        let secondLoad = rig.session.artworkLoad

        rig.deliverArtwork(for: "a")
        await secondLoad?.value
        let current: MPMediaItemArtwork? = rig.info[MPMediaItemPropertyArtwork]
        rig.deliverArtwork(for: "a")
        await firstLoad?.value

        let artwork: MPMediaItemArtwork? = rig.info[MPMediaItemPropertyArtwork]
        XCTAssertNotNil(current)
        XCTAssertTrue(artwork === current)
    }

    func testRefreshingMetadataRepublishesTheNewTitleAndArtwork() async {
        await playing()
        await rig.session.artworkLoad?.value
        let before: MPMediaItemArtwork? = rig.info[MPMediaItemPropertyArtwork]

        rig.retitled["a"] = "Edited"
        rig.session.refreshMetadata()
        await rig.session.artworkLoad?.value

        let artwork: MPMediaItemArtwork? = rig.info[MPMediaItemPropertyArtwork]
        XCTAssertEqual(title, "Edited")
        XCTAssertNotNil(before)
        XCTAssertFalse(artwork === before)
        XCTAssertTrue(artwork === rig.artworks["a"])
    }

    func testRefreshingMetadataLeavesElapsedTimeRateAndCommandsAlone() async {
        await playing()
        await rig.session.artworkLoad?.value
        let (elapsedBefore, rateBefore, enabled) = (elapsed, rate, rig.commands.enabled)
        let state = rig.info.playbackState

        rig.retitled["a"] = "Edited"
        rig.session.refreshMetadata()

        XCTAssertEqual(title, "Edited")
        XCTAssertEqual(elapsed, elapsedBefore)
        XCTAssertEqual(rate, rateBefore)
        XCTAssertEqual(duration, 10)
        XCTAssertEqual(rig.info.playbackState, state)
        XCTAssertEqual(rig.commands.enabled, enabled)
    }

    func testRefreshingMetadataWithNoItemWritesNothing() async {
        await rig.settle()
        let writes = rig.info.writes

        rig.session.refreshMetadata()

        XCTAssertEqual(rig.info.writes, writes)
        XCTAssertNil(rig.info.nowPlayingInfo)
    }

    func testRefreshingMetadataAfterReleaseWritesNothing() async {
        await playing()
        rig.session.release()
        let writes = rig.info.writes
        rig.retitled["a"] = "Edited"

        rig.session.refreshMetadata()

        XCTAssertEqual(rig.info.writes, writes)
        XCTAssertNil(rig.info.nowPlayingInfo)
    }

    func testArtworkLoadedBeforeARefreshIsDropped() async {
        rig.heldArtwork = ["a"]
        rig.player.setItems(["a", "b"])
        await rig.settle()
        let first = rig.session.artworkLoad
        rig.session.refreshMetadata()
        let second = rig.session.artworkLoad
        await Task.yield()

        rig.deliverArtwork(for: "a")
        await second?.value
        let current: MPMediaItemArtwork? = rig.info[MPMediaItemPropertyArtwork]
        rig.deliverArtwork(for: "a")
        await first?.value

        let artwork: MPMediaItemArtwork? = rig.info[MPMediaItemPropertyArtwork]
        XCTAssertNotNil(current)
        XCTAssertTrue(artwork === current)
    }
}
