import Foundation
import PlaybackRender
import XCTest
@_spi(Testing) @testable import PlaybackPlayer

/// Every source the player hands the transport is released once the transport lets go of it, so a
/// download behind it ends; a seek within what is set releases nothing.
@MainActor
final class PlayerSourceReleaseTests: XCTestCase {
    private var rig: PlayerRig!
    private var player: Player<String> { rig.player }

    override func setUp() async throws {
        rig = PlayerRig()
    }

    func testASkipPastTheArmedNextReleasesTheCurrentAndTheNext() {
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 1)

        player.seek(to: 0, itemAt: 2)
        rig.pump()

        XCTAssertEqual(rig.factory.released, ["a", "b"])
    }

    func testRemovingTheCurrentReleasesItOnceTheNextIsHeard() {
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 1)

        player.remove(at: 0)
        rig.run(for: 1)

        XCTAssertEqual(player.currentItem, "b")
        XCTAssertEqual(rig.factory.released, ["a"])
    }

    func testReplaceItemsReleasesAReplacedNext() {
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 1)

        player.replaceItems(["a", "c"], currentIndex: 0)
        rig.pump()

        XCTAssertEqual(rig.factory.calls, ["a", "b", "c"])
        XCTAssertEqual(rig.factory.released, ["b"])
    }

    func testReplaceItemsWithAnotherCurrentReleasesEverySourceSet() {
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 1)

        player.replaceItems(["x", "y"], currentIndex: 0)
        rig.pump()

        XCTAssertEqual(rig.factory.released, ["a", "b"])
    }

    func testStopReleasesEverySourceSet() {
        player.setItems(["a", "b"])
        player.play()
        rig.run(for: 1)

        player.stop()
        rig.pump()

        XCTAssertEqual(rig.factory.released, ["a", "b"])
    }

    func testUnloadingDropsTheItemsKeptForProcessors() {
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 1)

        player.stop()
        XCTAssertEqual(player.keyedItems.count, 0)

        player.play()
        player.removeAll()
        XCTAssertEqual(player.keyedItems.count, 0)
    }

    func testASeekReleasesNothing() {
        player.setItems(["a", "b"])
        player.play()
        rig.run(for: 1)

        player.seek(to: 5)
        rig.run(for: 1)
        player.seek(to: 1)
        rig.run(for: 1)

        XCTAssertEqual(rig.factory.released, [])
    }

    func testAGaplessJoinReleasesTheItemBeforeOnceTheJoinIsHeard() {
        player.setItems(["a", "b"])
        player.play()
        rig.run(for: 9)
        XCTAssertEqual(rig.factory.released, [], "decode is past the join, but a is still heard")

        rig.run(for: 2)

        XCTAssertEqual(player.currentItem, "b")
        XCTAssertEqual(rig.factory.released, ["a"])
    }
}
