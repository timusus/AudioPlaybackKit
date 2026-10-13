import PlaybackPlayer
import PlaybackPlayerTestSupport
import PlaybackRender
import PlaybackRenderTestSupport
import XCTest

/// Stands in for the app's coordinator: the one place that decides what the UI's buttons do and
/// what happens to the queue when an item fails.
@MainActor
final class PlaybackCoordinator {
    let player: Player<Track>
    private(set) var skipped: [Track] = []

    init(player: Player<Track>) {
        self.player = player
    }

    func togglePlayPause() {
        player.playWhenReady.toggle()
    }

    func skipFailedItem() {
        guard let item = player.currentItem, player.error != nil else { return }
        skipped.append(item)
        player.skipToNext()
        // A failed player is idle and stays so across a skip; `play()` prepares the new item.
        player.play()
    }
}

// The rig is a real `Player` on a fake speaker, fake audio session and a clock the test turns, so
// these run in milliseconds and cannot flake. The coordinator under test is the app's own.
@MainActor
final class TestAppCodeRecipe: XCTestCase {
    private let factory = FakeItemFactory<Track>()

    private func makeRig() -> PlayerTestRig<Track> {
        let factory = factory
        return PlayerTestRig { try factory.make($0) }
    }

    func testTogglePlaysAndPauses() {
        let rig = makeRig()
        let coordinator = PlaybackCoordinator(player: rig.player)
        rig.player.setItems([Track(id: 1)])

        coordinator.togglePlayPause()
        rig.run(for: 1)
        XCTAssertTrue(rig.player.isPlaying)
        XCTAssertEqual(rig.session.activations, 1)

        coordinator.togglePlayPause()
        rig.settle()
        XCTAssertFalse(rig.player.isPlaying)
    }

    func testAnInterruptionPausesAndResumesPlayback() {
        let rig = makeRig()
        rig.player.setItems([Track(id: 1)])
        rig.player.play()
        rig.run(for: 1)

        rig.session.interruptionBegan()
        XCTAssertEqual(rig.player.suppression, .interruption)

        rig.session.interruptionEnded(shouldResume: true)
        rig.run(for: 1)
        XCTAssertTrue(rig.player.isPlaying)
    }

    // Script the failure instead of arranging a bad file: `unopenable` throws when decode opens the item.
    func testTheCoordinatorSkipsAnItemThatFailsToOpen() {
        factory.unopenable = [Track(id: 2)]
        let rig = makeRig()
        let coordinator = PlaybackCoordinator(player: rig.player)
        rig.player.setItems([Track(id: 1), Track(id: 2), Track(id: 3)])
        rig.player.play()
        rig.run(for: 11)
        XCTAssertEqual(rig.player.error?.kind, .source)

        coordinator.skipFailedItem()
        rig.run(for: 2)

        XCTAssertEqual(coordinator.skipped, [Track(id: 2)])
        XCTAssertEqual(rig.player.currentItem, Track(id: 3))
        XCTAssertTrue(rig.player.isPlaying)
    }

    // A dropped connection halfway through an item: it fails at that frame, not at open.
    func testAnItemThatFailsHalfwayReportsWhere() {
        factory.failingAtFrame = [Track(id: 1): 40]
        let rig = makeRig()
        var failed: [Int] = []
        rig.onEvent = { if case let .itemFailed(index, _) = $0 { failed.append(index) } }
        rig.player.setItems([Track(id: 1)])
        rig.player.play()

        rig.run(for: 8)

        XCTAssertEqual(failed, [0])
        XCTAssertEqual(rig.player.state, .idle)
    }
}
