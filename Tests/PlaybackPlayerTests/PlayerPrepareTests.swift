import Foundation
import PlaybackRender
import XCTest
@_spi(Testing) @testable import PlaybackPlayer

/// `prepare()`, media3 `Player.prepare()`, on the fake output: items are ten seconds at 8 Hz, and each
/// item's samples start at its own base (a 0, b 1000, ...).
@MainActor
final class PlayerPrepareTests: XCTestCase {
    private var rig: PlayerRig!
    private var player: Player<String> { rig.player }

    override func setUp() async throws {
        rig = PlayerRig()
    }

    // #147: a failure skip while paused readied the next item only by sending the list again.
    func testPrepareAfterAFailureLoadsTheCurrentItemPaused() async {
        rig.factory.failingAtFrame = ["a": 40]
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 6)
        XCTAssertNotNil(player.error)
        player.pause()
        player.skipToNext()
        XCTAssertEqual(player.state, .idle)
        let written = rig.output.enqueues.count
        let calls = rig.factory.calls.count

        player.prepare()
        XCTAssertNil(player.error)
        XCTAssertEqual(player.state, .buffering)
        XCTAssertEqual(player.items, ["a", "b", "c"])
        XCTAssertEqual(Array(rig.factory.calls.dropFirst(calls)), ["b", "c"], "b loaded and c armed")
        rig.pump()
        XCTAssertEqual(player.state, .ready)
        XCTAssertFalse(player.playWhenReady)
        XCTAssertEqual(rig.output.rate, 0)
        XCTAssertEqual(rig.firstSampleWritten(skipping: written), 1000)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.failedIndices(events), [0])
    }

    // media3 prepares from the position kept by `stop()`, and plays at once if `playWhenReady`.
    func testPrepareAfterAStopPlaysFromThePositionIfPlayWhenReady() {
        player.setItems(["a", "b"])
        player.play()
        rig.run(for: 3)
        player.stop()
        XCTAssertEqual(player.state, .idle)
        let written = rig.output.enqueues.count

        player.prepare()
        rig.run(for: 1)
        XCTAssertEqual(player.state, .ready)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(rig.firstSampleWritten(skipping: written), 24)
    }

    func testPrepareDoesNothingUnlessIdle() {
        player.prepare()
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(rig.factory.calls, [])

        player.setItems(["a", "b"])
        rig.pump()
        player.prepare()
        XCTAssertEqual(rig.factory.calls, ["a", "b"])
        XCTAssertEqual(player.state, .ready)
    }

    // The source's failure to make is reported as from `play()`.
    func testPrepareOfAnItemThatFailsToMakeReportsIt() async {
        rig.factory.failing = ["a"]
        player.setItems(["a"])
        XCTAssertNotNil(player.error)

        player.prepare()
        XCTAssertEqual(player.state, .idle)
        XCTAssertNotNil(player.error)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.failedIndices(events), [0, 0])
    }
}
