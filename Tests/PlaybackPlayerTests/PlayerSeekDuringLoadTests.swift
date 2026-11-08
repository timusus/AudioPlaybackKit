import Foundation
import XCTest
@_spi(Testing) @testable import PlaybackPlayer
@_spi(Testing) import PlaybackPlayerTestSupport

/// A seek or skip that arrives while the current item's source has not opened is kept and acts at
/// once; the latest wins, and nothing of the item left is heard after it.
@MainActor
final class PlayerSeekDuringLoadTests: XCTestCase {
    private var rig: PlayerRig!
    private var player: Player<String> { rig.player }

    override func setUp() async throws {
        rig = PlayerRig()
    }

    /// "a" plays, then "c" (not armed: "b" is) is loading when the test acts; nothing has been pumped since.
    private func loadingC() {
        player.setItems(["a", "b", "c", "d"])
        player.play()
        rig.run(for: 1)
        player.seek(to: 0, itemAt: 2)
        XCTAssertNil(player.duration, "the new item has not opened")
    }

    func testTheLatestSeekDuringALoadLandsOnceTheItemOpensAndTheOldItemIsNotHeard() {
        loadingC()
        let written = rig.output.enqueues.count

        player.seek(to: 3)
        player.seek(to: 5)
        XCTAssertEqual(player.position, 5)
        rig.pump()

        XCTAssertEqual(player.position, 5)
        XCTAssertEqual(rig.firstSampleWritten(skipping: written), 2040, "c from 5 s; a's audio is not heard")
    }

    func testASeekPendingWhenTheLoadFailsIsNotAddedToByALaterSkip() {
        rig.factory.unopenable = ["a"]
        player.setItems(["a"])
        player.play()
        player.seek(to: 5)
        rig.pump()
        XCTAssertNotNil(player.error)

        player.seek(to: 20)
        player.seek(by: 30)

        XCTAssertEqual(player.position, 50)
    }

    func testASkipDuringALoadActsAtOnce() {
        loadingC()
        let written = rig.output.enqueues.count

        player.skipToNext()
        XCTAssertEqual(player.currentItem, "d")
        rig.pump()

        XCTAssertEqual(rig.firstSampleWritten(skipping: written), 3000)
        XCTAssertEqual(player.position, 0)
    }
}
