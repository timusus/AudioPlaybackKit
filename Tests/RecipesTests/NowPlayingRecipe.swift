import MediaPlayer
import PlaybackNowPlaying
import PlaybackNowPlayingTestSupport
import PlaybackPlayer
import PlaybackPlayerTestSupport
import XCTest

@MainActor
final class NowPlayingRecipe: XCTestCase {
    private let factory = FakeItemFactory<Track>()
    private var wall: TimeInterval = 0

    // In the app: `NowPlayingSession(player: player, metadata: { ... })`, kept for the app's life.
    // Here the fake centres stand in for the system's, and `wall` is the session's clock.
    private func makeSession(_ rig: PlayerTestRig<Track>) -> (NowPlayingSession<Track>, FakeNowPlayingInfoCenter, FakeRemoteCommandCenter) {
        let info = FakeNowPlayingInfoCenter()
        let commands = FakeRemoteCommandCenter()
        let session = NowPlayingSession(
            player: rig.player,
            metadata: { NowPlayingMetadata(title: "Track \($0.id)", artist: "Artist") },
            infoCenter: info,
            commandCenter: commands,
            now: { [unowned self] in wall }
        )
        return (session, info, commands)
    }

    func testTheLockScreenShowsTheItemAndTheCommandsDriveThePlayer() async {
        let rig = PlayerTestRig<Track> { [factory] in try factory.make($0) }
        let (session, info, commands) = makeSession(rig)
        rig.player.setItems([Track(id: 1), Track(id: 2)])
        rig.player.play()
        rig.run(for: 2)
        wall = 2
        await session.settle()

        XCTAssertEqual(info[MPMediaItemPropertyTitle], "Track 1")
        XCTAssertEqual(info[MPMediaItemPropertyArtist], "Artist")
        XCTAssertEqual(info.playbackState, .playing)
        // A command is enabled only while the player can do it.
        XCTAssertTrue(commands.enabled.isSuperset(of: [.play, .pause, .nextTrack]))

        // The lock screen's scrubber and next button, as the system would send them.
        XCTAssertEqual(commands.press(.changePlaybackPosition, .position(6)), .success)
        rig.run(for: 1)
        XCTAssertEqual(rig.player.position, 7, accuracy: 0.3)

        XCTAssertEqual(commands.press(.nextTrack), .success)
        rig.run(for: 1)
        await session.settle()
        XCTAssertEqual(rig.player.currentItem, Track(id: 2))
        XCTAssertEqual(info[MPMediaItemPropertyTitle], "Track 2")

        XCTAssertEqual(commands.press(.pause), .success)
        rig.settle()
        await session.settle()
        XCTAssertFalse(rig.player.playWhenReady)
        XCTAssertEqual(info.playbackState, .paused)
    }

    // Release when the player goes away: both centres are global, so a stale handler would outlive it.
    func testReleaseClearsTheCommandsAndTheInfo() async {
        let rig = PlayerTestRig<Track> { [factory] in try factory.make($0) }
        let (session, info, commands) = makeSession(rig)
        rig.player.setItems([Track(id: 1)])
        rig.player.play()
        rig.run(for: 1)
        await session.settle()
        XCTAssertFalse(commands.enabled.isEmpty)

        session.release()

        XCTAssertTrue(commands.enabled.isEmpty)
        XCTAssertNil(info.nowPlayingInfo)
    }
}
