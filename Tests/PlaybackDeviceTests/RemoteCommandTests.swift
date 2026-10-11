import MediaPlayer
import XCTest
@testable import PlaybackNowPlaying
@testable import PlaybackPlayer

/// The lock screen and Control Center rows: each command through its registered target, with what
/// the real centres then show.
final class RemoteCommandTests: DeviceTestCase {
    func testPlayPauseAndToggle() async {
        await rig.startPlaying()
        XCTAssertEqual(rig.send(.pause), .success)
        await rig.waitUntil("paused") { !rig.player.isPlaying }
        XCTAssertFalse(rig.player.playWhenReady)
        await rig.settle()
        XCTAssertEqual(rig.shownState, .paused)
        XCTAssertEqual(rig.shownRate, 0)
        await rig.assertSilent()

        XCTAssertEqual(rig.send(.togglePlayPause), .success)
        await rig.waitUntil("playing") { rig.player.isPlaying }
        await rig.settle()
        XCTAssertEqual(rig.shownState, .playing)
        XCTAssertEqual(rig.shownRate, 1)
        await rig.assertAudible(over: 0.5)

        XCTAssertEqual(rig.send(.togglePlayPause), .success)
        await rig.waitUntil("paused") { !rig.player.isPlaying }
        XCTAssertEqual(rig.send(.play), .success)
        await rig.waitUntil("playing") { rig.player.isPlaying }
        await rig.assertAudible(over: 0.5)
    }

    func testTrackSkipsMoveBetweenItemsAndPreviousOnTheFirstRestartsIt() async {
        await rig.startPlaying()
        await rig.settle()
        XCTAssertEqual(rig.shownTitle, Fixture.items[0])
        XCTAssertEqual(rig.shownDuration ?? 0, 4, accuracy: 0.05)
        XCTAssertNil(rig.send(.skipForward, .interval(15)), "no interval buttons with .tracks")
        XCTAssertNil(rig.send(.skipBackward, .interval(15)))

        XCTAssertEqual(rig.send(.nextTrack), .success)
        await rig.waitUntil("item 2 heard") { rig.player.currentIndex == 1 && rig.player.isPlaying && rig.player.duration != nil }
        await rig.settle()
        XCTAssertEqual(rig.shownTitle, Fixture.items[1])
        XCTAssertEqual(rig.shownDuration ?? 0, 8, accuracy: 0.05)
        XCTAssertEqual(rig.shownElapsed ?? -1, 0, accuracy: 0.25, "elapsed starts at 0")

        XCTAssertEqual(rig.send(.previousTrack), .success)
        await rig.waitUntil("item 1 heard") { rig.player.currentIndex == 0 && rig.player.isPlaying }
        await rig.settle()
        XCTAssertEqual(rig.shownTitle, Fixture.items[0])

        await rig.sleep(1)
        XCTAssertEqual(rig.send(.previousTrack), .success, "previous stays enabled on the first item")
        await rig.waitUntil("restarted") { rig.player.position < 0.5 }
        XCTAssertEqual(rig.player.currentIndex, 0)
        await rig.settle()
        XCTAssertEqual(rig.shownElapsed ?? -1, 0, accuracy: 0.25)
        XCTAssertTrue(rig.remote(.previousTrack).isEnabled)
        await rig.assertAudible(over: 0.5)
    }

    func testIntervalSkipsMoveByTheConfiguredSeconds() async {
        await makeRig(skipMode: .intervals(forward: 3, backward: 2))
        let center = MPRemoteCommandCenter.shared()
        XCTAssertEqual(center.skipForwardCommand.preferredIntervals, [3])
        XCTAssertEqual(center.skipBackwardCommand.preferredIntervals, [2])
        await rig.startPlaying(at: 2, position: 2)
        XCTAssertNil(rig.send(.nextTrack), "no next with .intervals")
        XCTAssertNil(rig.send(.previousTrack))

        var before = rig.player.position
        XCTAssertEqual(rig.send(.skipForward, .interval(3)), .success)
        await rig.waitUntil("skipped forward") { rig.player.position > before + 2.5 }
        XCTAssertEqual(rig.player.position, before + 3, accuracy: 0.25)

        before = rig.player.position
        XCTAssertEqual(rig.send(.skipBackward, .interval(2)), .success)
        await rig.waitUntil("skipped back") { rig.player.position < before - 1.5 }
        XCTAssertEqual(rig.player.position, before - 2, accuracy: 0.25)
        await rig.assertAudible(over: 0.5)
    }

    func testScrubberSeeksAndElapsedKeepsCounting() async {
        await rig.startPlaying(at: 2)
        XCTAssertEqual(rig.send(.changePlaybackPosition, .position(6)), .success)
        await rig.waitUntil("seek landed") { rig.didSend { if case .seekLanded = $0 { true } else { false } } }
        XCTAssertEqual(rig.player.position, 6, accuracy: 0.25)
        await rig.settle()
        XCTAssertEqual(rig.shownElapsed ?? -1, 6, accuracy: 0.25)
        XCTAssertEqual(rig.shownRate, 1, "keeps counting")
        await rig.assertAudible(over: 0.5)
    }

    func testRateCommandChangesTheHeardRateAndTheShownOne() async {
        XCTAssertEqual(MPRemoteCommandCenter.shared().changePlaybackRateCommand.supportedPlaybackRates, [1, 1.5, 2])
        await rig.startPlaying(at: 2)
        XCTAssertEqual(rig.send(.changePlaybackRate, .rate(1.5)), .success)
        XCTAssertEqual(rig.player.rate, 1.5)
        await rig.sleep(0.3)
        await rig.settle()
        XCTAssertEqual(rig.shownRate, 1.5)
        await rig.assertAudible()
    }

    func testNextOnTheLastItemIsOffWithRepeatOffAndWrapsWithRepeatAll() async {
        await rig.startPlaying(at: 2)
        await rig.settle()
        XCTAssertNil(rig.send(.nextTrack), "next is greyed out on the last item")

        rig.player.repeatMode = .all
        await rig.settle()
        XCTAssertEqual(rig.send(.nextTrack), .success)
        await rig.waitUntil("wrapped to item 1") { rig.player.currentIndex == 0 && rig.player.isPlaying }
        await rig.settle()
        XCTAssertEqual(rig.shownTitle, Fixture.items[0])
    }

    func testScrubbingAndSkipsAreOffUntilTheDurationIsKnown() async {
        await makeRig(skipMode: .intervals(forward: 3, backward: 3))
        rig.gated = [Fixture.items[1]]
        rig.player.setItems(Fixture.items, startIndex: 1)
        rig.player.play()
        await rig.sleep(0.3)
        await rig.settle()
        XCTAssertNil(rig.player.duration)
        XCTAssertNil(rig.send(.changePlaybackPosition, .position(2)), "no scrubbing before the item opens")
        XCTAssertNil(rig.send(.skipForward, .interval(3)))
        XCTAssertNil(rig.send(.skipBackward, .interval(3)))
        XCTAssertEqual(rig.shownTitle, Fixture.items[1], "the title shows at once")

        rig.gates.forEach { $0.release() }
        await rig.waitUntil("opened") { rig.player.duration != nil }
        await rig.settle()
        XCTAssertTrue(rig.remote(.changePlaybackPosition).isEnabled)
        XCTAssertTrue(rig.remote(.skipForward).isEnabled)
        XCTAssertTrue(rig.remote(.skipBackward).isEnabled)
        XCTAssertEqual(rig.shownDuration ?? 0, 8, accuracy: 0.05)
    }
}
