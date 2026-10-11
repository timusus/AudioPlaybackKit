import Foundation
import PlaybackRender
import XCTest
@testable import PlaybackPlayer

/// Transport events that race the app's calls, seek landings and the gapless crossing, on the fake
/// output: items are ten seconds at 8 Hz, and each item's samples start at its own base (a 0, b 1000, ...).
@MainActor
final class PlayerTransportEventTests: XCTestCase {
    private var rig: PlayerRig!
    private var player: Player<String> { rig.player }

    override func setUp() async throws {
        rig = PlayerRig()
    }

    func testASameItemPositionInFlightWhenASeekIsIssuedIsDropped() {
        player.setItems(["a"])
        player.play()
        rig.run(for: 1)
        rig.output.advance(by: 0.25)
        rig.timer.fire()

        player.seek(to: 5)
        XCTAssertEqual(player.position, 5)
        rig.player.drainTransportEvents()
        XCTAssertEqual(player.position, 5, "a's 1.25 s was sent before the seek was taken")
        rig.pump()
        XCTAssertEqual(player.position, 5)
    }

    func testSeekLandedIsSentOnceTheSeeksAudioIsHeard() async {
        player.setItems(["a", "b"])
        player.play()
        rig.run(for: 1)

        player.seek(to: 5)
        rig.settle()
        rig.pump()
        rig.output.advance(by: 0.25)
        rig.pump()

        XCTAssertEqual(player.position, 5.25)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.seeksLanded(events), [.init(index: 0, position: 5)])
    }

    func testRapidSeekByPressesAddUpBeforeTheFirstLands() async {
        player.setItems(["a", "b"])
        player.play()
        rig.run(for: 1)
        let written = rig.output.enqueues.count

        player.seek(by: 2)
        player.seek(by: 2)
        rig.pump()
        XCTAssertEqual(rig.firstSampleWritten(skipping: written), 40)
        XCTAssertEqual(player.position, 5)

        // The landed target is forgotten, and an item change starts from the new item's position.
        player.seek(by: 1)
        player.skipToNext()
        player.seek(by: 1)
        rig.pump()
        XCTAssertEqual(player.currentItem, "b")
        XCTAssertEqual(player.position, 1)

        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.seeksLanded(events), [.init(index: 0, position: 5), .init(index: 1, position: 1)])
    }

    func testAStaleStatusInFlightAcrossASkipIsDropped() {
        player.setItems(["a"])
        player.play()
        rig.run(for: 9.75)
        let stale = rig.inFlight {
            rig.output.advance(by: 0.25)
            rig.timer.fire()
        }
        XCTAssertTrue(stale.contains { if case .status(.ended) = $0 { true } else { false } })
        let skip = rig.inFlight {
            player.insert(["b"], at: 1)
            player.skipToNext()
        }

        rig.deliver(stale)
        XCTAssertNotEqual(player.state, .ended, "a ended before the skip to b was taken")
        rig.deliver(skip)
        rig.pump()
        XCTAssertEqual(player.currentItem, "b")
        XCTAssertNotEqual(player.state, .ended)
    }

    func testCrossingIntoTheNextAdvancesAndArmsTheOneAfter() async {
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 11)

        XCTAssertEqual(player.currentIndex, 1)
        XCTAssertEqual(player.currentItem, "b")
        XCTAssertEqual(player.position, 1)
        XCTAssertEqual(player.duration, 10)
        XCTAssertEqual(rig.factory.calls, ["a", "b", "c"])
        rig.run(for: 10)
        XCTAssertEqual(player.currentItem, "c")
        XCTAssertEqual(player.position, 1)

        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [
            .init(from: 0, to: 1, reason: .auto),
            .init(from: 1, to: 2, reason: .auto),
        ])
    }

    func testTheEndOfTheListEndsOnTheLastItem() async {
        player.setItems(["a", "b"])
        player.play()
        rig.run(for: 21)

        XCTAssertEqual(player.currentIndex, 1)
        XCTAssertEqual(player.state, .ended)
        XCTAssertGreaterThan(player.position, 9, "b's positions")
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 0, to: 1, reason: .auto)])
    }

    func testRemovingTheCurrentItemWithAPositionInFlightPlaysTheNextFromZero() {
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 1)
        let stale = rig.inFlight {
            rig.output.advance(by: 0.25)
            rig.timer.fire()
        }
        let written = rig.output.enqueues.count

        player.remove(at: 0)
        rig.deliver(stale)
        XCTAssertEqual(player.currentItem, "b")
        XCTAssertEqual(player.position, 0)
        rig.pump()
        XCTAssertEqual(rig.firstSampleWritten(skipping: written), 1000)
        XCTAssertEqual(player.position, 0)
        XCTAssertEqual(player.currentIndex, 0)
    }

    func testSeeksAndSkipsAfterStopStayIdleUntilPlay() async {
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 1)
        player.stop()
        rig.pump()
        let written = rig.output.enqueues.count

        player.seek(to: 2, itemAt: 1)
        rig.pump()
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(player.currentIndex, 1)
        XCTAssertEqual(player.position, 2)
        player.skipToNext()
        rig.pump()
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(player.currentIndex, 2)
        XCTAssertEqual(player.position, 0)
        XCTAssertEqual(rig.factory.calls, ["a", "b"])
        XCTAssertEqual(rig.output.enqueues.count, written)

        player.play()
        rig.pump()
        XCTAssertEqual(rig.factory.calls, ["a", "b", "c"])
        XCTAssertEqual(rig.firstSampleWritten(skipping: written), 2000)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [
            .init(from: 0, to: 1, reason: .seek),
            .init(from: 1, to: 2, reason: .seek),
        ])
    }
}
