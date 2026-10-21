import Foundation
import PlaybackRender
@_spi(Testing) import PlaybackPlayerTestSupport
import XCTest
@_spi(Testing) @testable import PlaybackPlayer

/// `startGate`: items are ten seconds at 8 Hz, and each item's samples start at its own base (a 0, b 1000, ...).
@MainActor
final class PlayerStartGateTests: XCTestCase {
    /// Holds each item's gate until the test opens it.
    @MainActor
    private final class Gates {
        private(set) var entered: [String] = []
        private var waiting: [String: CheckedContinuation<Void, Never>] = [:]

        func hold(_ item: String) async {
            entered.append(item)
            await withCheckedContinuation { waiting[item] = $0 }
        }

        func open(_ item: String) {
            waiting.removeValue(forKey: item)?.resume()
        }
    }

    @MainActor
    private final class GateEndLog {
        var ends: [StartGateEnd<String>] = []
    }

    private var rig: PlayerRig!
    private var gates: Gates!
    private var player: Player<String> { rig.player }

    override func setUp() async throws {
        rig = PlayerRig()
        gates = Gates()
        let gates = gates!
        player.startGate = { await gates.hold($0) }
    }

    private func letGateTasksRun() async {
        for _ in 0..<10 { await Task.yield() }
    }

    func testTheGateHoldsTheStartUntilItReturns() async {
        player.setItems(["a", "b"])
        player.play()
        rig.run(for: 1)
        await letGateTasksRun()
        XCTAssertEqual(gates.entered, ["a"])
        XCTAssertEqual(player.state, .ready, "prepared while it waits")
        XCTAssertEqual(rig.output.rate, 0)
        XCTAssertEqual(player.position, 0)

        gates.open("a")
        await letGateTasksRun()
        rig.run(for: 1)
        XCTAssertNotEqual(rig.output.rate, 0)
        XCTAssertGreaterThan(player.position, 0)
    }

    func testAPauseDuringTheGateKeepsItPaused() async {
        player.setItems(["a"])
        player.play()
        rig.run(for: 1)
        await letGateTasksRun()
        player.pause()
        gates.open("a")
        await letGateTasksRun()
        rig.run(for: 1)
        XCTAssertEqual(rig.output.rate, 0)
        XCTAssertEqual(player.position, 0)

        player.play()
        rig.run(for: 1)
        XCTAssertNotEqual(rig.output.rate, 0, "a pause consumed the gate")
        XCTAssertEqual(gates.entered, ["a"])
    }

    func testReplacingTheItemDuringTheGateNeverStartsTheOldOne() async {
        player.setItems(["a"])
        player.play()
        rig.run(for: 1)
        await letGateTasksRun()
        player.setItems(["b"])
        rig.run(for: 1)
        await letGateTasksRun()
        XCTAssertEqual(gates.entered, ["a", "b"])

        gates.open("a")
        await letGateTasksRun()
        rig.run(for: 1)
        XCTAssertEqual(rig.output.rate, 0, "b is still gated")

        let written = rig.output.enqueues.count
        gates.open("b")
        await letGateTasksRun()
        rig.run(for: 1)
        XCTAssertNotEqual(rig.output.rate, 0)
        XCTAssertGreaterThan(player.position, 0)
        XCTAssertEqual(rig.output.enqueues.dropFirst(written).first?.samples.first.map { $0 >= 1000 }, true)
    }

    func testAStopDuringTheGateKeepsItIdle() async {
        player.setItems(["a"])
        player.play()
        rig.run(for: 1)
        await letGateTasksRun()
        player.stop()
        gates.open("a")
        await letGateTasksRun()
        rig.run(for: 1)
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(rig.output.rate, 0)
    }

    func testResumingAndGaplessJoinsAreNotGated() async {
        player.setItems(["a", "b"])
        player.play()
        await letGateTasksRun()
        gates.open("a")
        await letGateTasksRun()
        rig.run(for: 3)
        player.pause()
        player.play()
        rig.run(for: 9)
        XCTAssertEqual(player.currentIndex, 1)
        XCTAssertEqual(gates.entered, ["a"])
        XCTAssertNotEqual(rig.output.rate, 0)
    }

    func testAJumpToTheArmedNextDuringTheGateStillPlays() async {
        player.setItems(["a", "b"])
        player.play()
        rig.run(for: 1)
        await letGateTasksRun()
        player.skipToNext()
        rig.run(for: 1)
        await letGateTasksRun()
        XCTAssertEqual(player.currentIndex, 1)

        gates.open("a")
        gates.open("b")
        await letGateTasksRun()
        rig.run(for: 1)
        XCTAssertNotEqual(rig.output.rate, 0)
        XCTAssertGreaterThan(player.position, 0)
    }

    private func recordGateEnds() -> GateEndLog {
        let log = GateEndLog()
        player.startGateEnded = { log.ends.append($0) }
        return log
    }

    func testAPauseThenPlayQueuedBeforeTheGateTaskResumesReportsTheWithdrawalAtCancelTime() async {
        let log = recordGateEnds()
        player.setItems(["a"])
        player.play()
        rig.run(for: 1)
        await letGateTasksRun()
        player.pause()
        player.play()
        XCTAssertEqual(log.ends.map(\.item), ["a"], "reported before the cancelled task resumes")
        XCTAssertEqual(log.ends.map(\.reason), [.intentWithdrawn])
        gates.open("a")
        await letGateTasksRun()
        XCTAssertEqual(log.ends.count, 1)
    }

    func testAReplacedItemReportsItsGateSuperseded() async {
        let log = recordGateEnds()
        player.setItems(["a"])
        player.play()
        rig.run(for: 1)
        await letGateTasksRun()
        player.setItems(["b"])
        XCTAssertEqual(log.ends.map(\.item), ["a"])
        XCTAssertEqual(log.ends.map(\.reason), [.superseded])
    }

    func testAJumpToTheArmedNextReportsTheLeftItemSuperseded() async {
        let log = recordGateEnds()
        player.setItems(["a", "b"])
        player.play()
        rig.run(for: 1)
        await letGateTasksRun()
        player.skipToNext()
        XCTAssertEqual(log.ends.map(\.item), ["a"])
        XCTAssertEqual(log.ends.map(\.reason), [.superseded])
    }

    func testAPauseBeforeTheGateTaskFirstRunsNeverEntersTheGate() async {
        let log = recordGateEnds()
        player.setItems(["a"])
        player.play()
        player.pause()
        await letGateTasksRun()
        XCTAssertEqual(gates.entered, [])
        XCTAssertEqual(log.ends.map(\.reason), [.intentWithdrawn])
    }

    func testATransportFailureOfTheGatedItemReportsItsGateSuperseded() async {
        let log = recordGateEnds()
        player.setItems(["a"])
        player.play()
        rig.run(for: 1)
        await letGateTasksRun()
        rig.deliver([.failed(item: 1, error: FakeItemError(item: "a"))])
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(log.ends.map(\.item), ["a"])
        XCTAssertEqual(log.ends.map(\.reason), [.superseded])
    }

    func testALoadWhoseSourceFailsToMakeReportsTheOldGateSuperseded() async {
        let log = recordGateEnds()
        rig.factory.failing = ["b"]
        player.setItems(["a"])
        player.play()
        rig.run(for: 1)
        await letGateTasksRun()
        player.setItems(["b"])
        XCTAssertEqual(log.ends.map(\.item), ["a"])
        XCTAssertEqual(log.ends.map(\.reason), [.superseded])
    }

    func testAGateThatReturnsReportsNoEnd() async {
        let log = recordGateEnds()
        player.setItems(["a"])
        player.play()
        rig.run(for: 1)
        await letGateTasksRun()
        gates.open("a")
        await letGateTasksRun()
        rig.run(for: 1)
        XCTAssertNotEqual(rig.output.rate, 0)
        XCTAssertTrue(log.ends.isEmpty)
    }

    func testNoGateStartsAtOnce() {
        player.startGate = nil
        player.setItems(["a"])
        player.play()
        rig.run(for: 1)
        XCTAssertNotEqual(rig.output.rate, 0)
    }
}
