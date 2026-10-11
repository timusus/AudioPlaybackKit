import PlaybackPlayer
import PlaybackPlayerTestSupport
import PlaybackRender
import PlaybackRenderTestSupport
import XCTest

/// What an app's own test target can do: only the products' public API, no `@testable`, no SPI.
/// Copy this file as the start of a test for your own coordinator.
struct Episode: Hashable, Sendable {
    var id: Int
}

/// A stand-in for the app's coordinator: the one place that decides what the UI's buttons do.
@MainActor
final class PlaybackCoordinator {
    let player: Player<Episode>

    init(player: Player<Episode>) {
        self.player = player
    }

    func togglePlayPause() {
        player.playWhenReady.toggle()
    }
}

@MainActor
final class CoordinatorTests: XCTestCase {
    private func makeRig() -> PlayerTestRig<Episode> {
        let format = PCMFormat(sampleRate: 8, channelCount: 1)
        return PlayerTestRig<Episode> { _ in FakeItemSource(format: format, frames: 80, chunkFrames: 2) }
    }

    func testTogglePlaysAndPauses() {
        let rig = makeRig()
        let coordinator = PlaybackCoordinator(player: rig.player)
        rig.player.setItems([Episode(id: 1)])

        coordinator.togglePlayPause()
        rig.run(for: 1)
        XCTAssertTrue(rig.player.isPlaying)
        XCTAssertEqual(rig.session.activations, 1)

        coordinator.togglePlayPause()
        rig.settle()
        XCTAssertFalse(rig.player.isPlaying)
    }

    func testInterruptionSuppressesAndResumesPlayback() {
        let rig = makeRig()
        rig.player.setItems([Episode(id: 1)])
        rig.player.play()
        rig.run(for: 1)

        rig.session.interruptionBegan()
        XCTAssertEqual(rig.player.suppression, .interruption)

        rig.session.interruptionEnded(shouldResume: true)
        rig.run(for: 1)
        XCTAssertTrue(rig.player.isPlaying)
    }
}
