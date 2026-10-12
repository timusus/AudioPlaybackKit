import Foundation
import PlaybackRender
import XCTest
@_spi(Testing) @testable import PlaybackPlayer

/// `bufferedAhead` is the media written past what is heard: the transport keeps two seconds ahead,
/// and less once the list's end is written. Each fake item is 10 s at 8 Hz, in 0.25 s chunks.
@MainActor
final class PlayerBufferedAheadTests: XCTestCase {
    private var rig: PlayerRig!
    private var player: Player<String> { rig.player }

    override func setUp() async throws {
        rig = PlayerRig()
    }

    func testNothingIsBufferedBeforeALoad() {
        XCTAssertEqual(player.bufferedAhead, 0)
    }

    func testALoadBuffersTheTransportsTwoSecondsWhilePaused() {
        player.setItems(["a"])
        player.prepare()
        rig.run(for: 1)

        XCTAssertEqual(player.state, .ready)
        XCTAssertEqual(player.bufferedAhead, 2, accuracy: 1e-9)
    }

    func testOnlyWhatIsLeftIsBufferedNearTheListsEnd() {
        player.setItems(["a"])
        player.play()
        rig.run(for: 9)

        XCTAssertEqual(player.bufferedAhead, 1, accuracy: 1e-9)
    }
}
