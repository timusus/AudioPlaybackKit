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

    // The transport crossed into b before it took the seek on a, so it ignores the seek: b is heard.
    func testACrossingInFlightAcrossASeekTheTransportIgnoresStillAdvances() async {
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 9.75)
        let crossing = rig.inFlight {
            rig.output.advance(by: 0.5)
            rig.timer.fire()
        }
        XCTAssertTrue(crossing.contains { if case .crossed = $0 { true } else { false } })

        let answer = rig.inFlight { player.seek(to: 2) }
        rig.deliver(crossing)
        rig.deliver(answer)
        XCTAssertEqual(player.currentItem, "b")
        rig.run(for: 1)
        XCTAssertEqual(player.position, 1.25)
        rig.run(for: 10)
        XCTAssertEqual(player.currentItem, "c")

        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [
            .init(from: 0, to: 1, reason: .auto),
            .init(from: 1, to: 2, reason: .auto),
        ])
        XCTAssertEqual(PlayerRig.seeksLanded(events), [])
    }

    // The skip to the armed b is taken after the crossing into it, so the skip is what is heard.
    func testACrossingInFlightAcrossASkipToTheArmedNextIsTheSkip() async {
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 9.75)
        let crossing = rig.inFlight {
            rig.output.advance(by: 0.5)
            rig.timer.fire()
        }
        let written = rig.output.enqueues.count

        let skip = rig.inFlight { player.skipToNext() }
        rig.deliver(crossing)
        rig.deliver(skip)
        rig.pump()
        XCTAssertEqual(rig.firstSampleWritten(skipping: written), 1000)
        XCTAssertEqual(player.currentItem, "b")
        XCTAssertEqual(player.position, 0)
        rig.run(for: 10.5)
        XCTAssertEqual(player.currentItem, "c")

        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [
            .init(from: 0, to: 1, reason: .seek),
            .init(from: 1, to: 2, reason: .auto),
        ])
    }

    // The transport drops a failed next whatever the app called since, so the failure still counts.
    func testAFailedArmedNextInFlightWhileASeekIsPendingIsReported() async {
        rig.factory.unopenable = ["b"]
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 3)
        // Decode reaches b about two seconds ahead of the playhead.
        let failure = rig.inFlight { rig.run(for: 6) }
        XCTAssertTrue(failure.contains { if case .failed(2?, _) = $0 { true } else { false } })
        let answer = rig.inFlight { player.seek(to: 8) }
        rig.deliver(failure)
        rig.deliver(answer)
        rig.run(for: 3)
        XCTAssertEqual(player.currentItem, "a")
        XCTAssertEqual(player.state, .ended)

        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.failedIndices(events), [1])
        XCTAssertEqual(PlayerRig.transitions(events), [])
    }

    // A recovery restarts paused whatever the app intends; a seek after it must not show buffering.
    func testASeekAfterARecoveryKeepsTheTransportsPausedStatus() {
        player.setItems(["a"])
        player.play()
        rig.run(for: 1)
        rig.output.injectFailure()
        rig.pump()
        XCTAssertEqual(player.state, .ready)

        player.seek(to: 5)
        rig.settle()
        XCTAssertEqual(player.state, .ready)
        rig.run(for: 1)
        XCTAssertEqual(player.state, .ready)
        XCTAssertEqual(rig.output.rate, 0, "still paused")
    }

    func testASeekWhilePausedStaysReady() {
        player.setItems(["a"])
        rig.run(for: 1)
        XCTAssertEqual(player.state, .ready)

        player.seek(to: 5)
        rig.settle()
        XCTAssertEqual(player.state, .ready)
        rig.pump()
        XCTAssertEqual(player.state, .ready)
    }

    func testASeekWhilePlayingBuffersThenPlays() {
        player.setItems(["a"])
        player.play()
        rig.run(for: 1)
        XCTAssertEqual(player.state, .ready)

        player.seek(to: 5)
        rig.settle()
        XCTAssertEqual(player.state, .buffering)
        rig.pump()
        XCTAssertEqual(player.state, .ready)
        XCTAssertTrue(player.isPlaying)
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
