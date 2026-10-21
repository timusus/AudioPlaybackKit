import Foundation
import PlaybackRender
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

    func testNoGateStartsAtOnce() {
        player.startGate = nil
        player.setItems(["a"])
        player.play()
        rig.run(for: 1)
        XCTAssertNotEqual(rig.output.rate, 0)
    }
}
