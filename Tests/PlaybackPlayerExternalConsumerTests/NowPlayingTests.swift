import MediaPlayer
import PlaybackNowPlaying
import PlaybackNowPlayingTestSupport
import PlaybackPlayer
import PlaybackPlayerTestSupport
import XCTest

/// An app's test of what its session shows and how it answers the lock screen: public API only.
@MainActor
final class NowPlayingTests: XCTestCase {
    func testTheLockScreenShowsTheItemAndPausesIt() async {
        let rig = PlayerTestRig<Episode> { _ in try FakeItemFactory<Episode>().make(Episode(id: 1)) }
        let info = FakeNowPlayingInfoCenter()
        let commands = FakeRemoteCommandCenter()
        var wall: TimeInterval = 0
        let session = NowPlayingSession(
            player: rig.player,
            metadata: { NowPlayingMetadata(title: "Episode \($0.id)") },
            infoCenter: info,
            commandCenter: commands,
            now: { wall }
        )
        rig.player.setItems([Episode(id: 1)])
        rig.player.play()
        rig.run(for: 2)
        wall = 2
        await session.settle()

        XCTAssertEqual(info[MPMediaItemPropertyTitle], "Episode 1")
        XCTAssertEqual(info.playbackState, .playing)
        XCTAssertTrue(commands.enabled.contains(.pause))

        XCTAssertEqual(commands.press(.pause), .success)
        rig.settle()
        await session.settle()
        XCTAssertFalse(rig.player.playWhenReady)
        XCTAssertEqual(info.playbackState, .paused)
    }
}
