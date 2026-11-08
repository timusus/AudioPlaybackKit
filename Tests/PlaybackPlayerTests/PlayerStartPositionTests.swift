import Foundation
import XCTest
@_spi(Testing) @testable import PlaybackPlayer

/// The source factory learns where playback begins, so a server transcode opens there in one request.
@MainActor
final class PlayerStartPositionTests: XCTestCase {
    private var rig: PlayerRig!
    private var player: Player<String> { rig.player }

    override func setUp() async throws {
        rig = PlayerRig()
    }

    func testTheFactoryReceivesTheLoadPositionAndTheTransportStillSeeksToIt() {
        player.setItems(["a", "b"], startPosition: 5)
        rig.pump()

        XCTAssertEqual(rig.factory.calls, ["a", "b"])
        XCTAssertEqual(rig.factory.starts, [5, 0], "the armed next item starts at 0")
        XCTAssertEqual(rig.firstSampleWritten(skipping: 0), 40)
    }

    func testASkipLoadsTheNextItemAtItsStartAndArmsTheOneAfterAtZero() {
        player.setItems(["a", "b", "c"])
        rig.pump()
        player.seek(to: 3, itemAt: 2)
        rig.pump()

        XCTAssertEqual(Array(rig.factory.calls.suffix(1)), ["c"])
        XCTAssertEqual(rig.factory.starts.last, 3)
    }
}
