import Foundation
import XCTest
@_spi(Testing) @testable import PlaybackPlayer

/// `discontinuityCount` moves with every jump of `position` and never with playback, so an observer
/// such as Now Playing can tell a seek from the clock without guessing from positions.
@MainActor
final class PlayerDiscontinuityTests: XCTestCase {
    private var rig: PlayerRig!
    private var player: Player<String> { rig.player }

    override func setUp() async throws {
        rig = PlayerRig()
    }

    private func playing(_ items: [String] = ["a", "b"], for seconds: TimeInterval = 2) {
        player.setItems(items)
        player.play()
        rig.run(for: seconds)
    }

    private func jumps(_ body: () -> Void) -> Bool {
        let before = player.discontinuityCount
        body()
        return player.discontinuityCount != before
    }

    func testPlayingOnIsNoDiscontinuity() {
        playing()

        XCTAssertFalse(jumps { rig.run(for: 3) })
        XCTAssertGreaterThan(player.position, 4)
    }

    // media3 onPositionDiscontinuity(DISCONTINUITY_REASON_SEEK) is sent from the seek call, with the
    // new position already masked in.
    func testASeekMovesTheCountAtTheCallWithTheTargetPosition() {
        playing()
        let before = player.discontinuityCount

        player.seek(to: 2.5)

        XCTAssertEqual(player.discontinuityCount, before + 1)
        XCTAssertEqual(player.position, 2.5)
        XCTAssertFalse(jumps { rig.run(for: 1) }, "the landing plays on from the target")
    }

    func testEverySeekAndSkipIsADiscontinuity() {
        playing(["a", "b", "c"])

        XCTAssertTrue(jumps { player.seek(by: 0.5) })
        XCTAssertTrue(jumps { player.seek(to: 1, itemAt: 2) })
        XCTAssertTrue(jumps { player.skipToPrevious() })
        XCTAssertTrue(jumps { player.skipToNext() })
        XCTAssertTrue(jumps { player.setItems(["d"]) })
    }

    func testASeekWhileStoppedIsADiscontinuity() {
        playing()
        player.stop()

        XCTAssertTrue(jumps { player.seek(to: 5) })
        XCTAssertTrue(jumps { player.seek(to: 1, itemAt: 1) })
    }

    func testRemovingTheCurrentItemIsADiscontinuity() {
        playing(["a", "b", "c"])

        XCTAssertTrue(jumps { player.remove(at: 0) })
        XCTAssertEqual(player.position, 0)
    }

    // media3 DISCONTINUITY_REASON_AUTO_TRANSITION.
    func testAnAutomaticAdvanceIsADiscontinuity() {
        playing(for: 9)

        XCTAssertTrue(jumps { rig.run(for: 2) })
        XCTAssertEqual(player.currentIndex, 1)
    }

    func testARepeatOfTheSameItemIsADiscontinuity() {
        player.repeatMode = .one
        playing(["a"], for: 9)

        XCTAssertTrue(jumps { rig.run(for: 2) })
        XCTAssertLessThan(player.position, 2)
    }

    func testPlayOnEndedJumpsToZeroAtTheCall() {
        playing(["a"], for: 11)
        XCTAssertEqual(player.state, .ended)

        XCTAssertTrue(jumps { player.play() })
        XCTAssertEqual(player.position, 0)
    }
}
