import Foundation
import PlaybackRender
import XCTest
@_spi(Testing) @testable import PlaybackPlayer

/// `position` is read from the output clock on demand, and observers are the only wakeups a UI adds.
@MainActor
final class PlayerPositionTests: XCTestCase {
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

    /// Lets the main-actor hops the observers made run.
    private func drainMainActor() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testThePositionMovesWithTheClockWithNoPumpOrEvent() {
        playing()
        let before = player.position

        rig.output.advance(by: 0.5)

        XCTAssertEqual(player.position, before + 0.5, accuracy: 1e-9)
    }

    // The transport is in b before the main actor learns of the crossing: the read holds at a's end.
    func testThePositionNeverGoesBackBeforeTheCrossingIsDelivered() {
        playing(for: 9.5)
        let before = player.position

        let held = rig.inFlight {
            rig.output.advance(by: 1)
            rig.timer.fire()
        }
        XCTAssertFalse(held.isEmpty)
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertGreaterThanOrEqual(player.position, before)

        rig.deliver(held)
        XCTAssertEqual(player.currentIndex, 1)
        XCTAssertLessThan(player.position, 1)
    }

    func testAPeriodicObserverFiresEachIntervalWhilePlayingAndNotOnceCancelled() async {
        playing()
        var calls = 0
        let token = player.addPeriodicObserver(interval: 0.5) { calls += 1 }

        rig.run(for: 2)
        await drainMainActor()
        XCTAssertEqual(calls, 4)

        token.cancel()
        rig.run(for: 2)
        await drainMainActor()
        XCTAssertEqual(calls, 4)
    }

    // The fire is already on its way to the main actor when the app cancels.
    func testAFireQueuedForTheMainActorIsNotDeliveredOnceCancelled() async {
        playing()
        var calls = 0
        var crossed = 0
        let tokens = [
            player.addPeriodicObserver(interval: 0.5) { calls += 1 },
            player.addBoundaryObserver(times: [3]) { _, _ in crossed += 1 },
        ]

        rig.run(for: 2)
        tokens.forEach { $0.cancel() }
        await drainMainActor()

        XCTAssertEqual(calls, 0)
        XCTAssertEqual(crossed, 0)
    }

    func testAPeriodicObserverIsSilentWhilePaused() async {
        playing()
        var calls = 0
        let token = player.addPeriodicObserver(interval: 0.5) { calls += 1 }
        player.pause()

        rig.run(for: 2)
        await drainMainActor()

        XCTAssertEqual(calls, 0)
        token.cancel()
    }

    func testABoundaryObserverFiresOnceWhenPlayingCrossesItsTime() async {
        playing()
        var crossed: [String] = []
        let token = player.addBoundaryObserver(times: [3]) { item, time in crossed.append("\(item) \(time)") }

        rig.run(for: 3)
        await drainMainActor()

        XCTAssertEqual(crossed, ["a 3.0"])
        token.cancel()
    }

    // As AVPlayer's boundary observer: a seek past the time is a jump, not playback across it.
    func testASeekPastABoundaryDoesNotFireIt() async {
        playing()
        var crossed: [String] = []
        let token = player.addBoundaryObserver(times: [3]) { item, time in crossed.append("\(item) \(time)") }

        player.seek(to: 5)
        rig.run(for: 1)
        await drainMainActor()

        XCTAssertEqual(crossed, [])
        token.cancel()
    }
}
