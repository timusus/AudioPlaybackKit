import Foundation
import PlaybackRender
import XCTest
@_spi(Testing) @testable import PlaybackPlayer

/// `firstAudioRendered` after each load, seek and transition, and one `bufferingStarted` and
/// `bufferingEnded` pair per underrun while playing, never while paused. Each fake item is 10 s.
@MainActor
final class PlayerTelemetryEventTests: XCTestCase {
    private var rig: PlayerRig!
    private var player: Player<String> { rig.player }
    private var events: [PlayerEvent<String>] = []

    override func setUp() async throws {
        rig = PlayerRig()
        player.onEvent = { [weak self] in self?.events.append($0) }
    }

    /// Each event's case name, in the order sent.
    private var names: [String] {
        events.map { String(String(describing: $0).prefix { $0 != "(" }) }
    }

    private var telemetry: [String] {
        names.filter { ["firstAudioRendered", "bufferingStarted", "bufferingEnded"].contains($0) }
    }

    private var firstAudio: [PlayerRig.Landing] {
        events.compactMap {
            guard case let .firstAudioRendered(index, position) = $0 else { return nil }
            return PlayerRig.Landing(index: index, position: position)
        }
    }

    // MARK: First audio

    func testALoadWhilePlayingSendsFirstAudioOnce() {
        player.setItems(["a"], startPosition: 2)
        player.play()
        rig.run(for: 3)

        XCTAssertEqual(firstAudio, [PlayerRig.Landing(index: 0, position: 2)])
    }

    func testAPausedLoadSendsFirstAudioOnlyOncePlaying() {
        player.setItems(["a"])
        player.prepare()
        rig.run(for: 2)
        XCTAssertEqual(player.state, .ready)
        XCTAssertEqual(firstAudio, [])

        player.play()
        rig.run(for: 1)

        XCTAssertEqual(firstAudio.map(\.index), [0])
    }

    func testASeekSendsFirstAudioAfterItLands() {
        player.setItems(["a"])
        player.play()
        rig.run(for: 3)
        events = []

        player.seek(to: 6)
        rig.run(for: 1)

        XCTAssertEqual(firstAudio, [PlayerRig.Landing(index: 0, position: 6)])
        XCTAssertEqual(names, ["seekLanded", "firstAudioRendered"])
    }

    func testAGaplessTransitionSendsFirstAudioForTheNextItem() {
        player.setItems(["a", "b"])
        player.play()
        rig.run(for: 1)
        events = []

        rig.run(for: 10)

        XCTAssertEqual(names, ["itemTransition", "firstAudioRendered"])
        XCTAssertEqual(firstAudio.map(\.index), [1])
    }

    func testAResumeSendsNoFirstAudio() {
        player.setItems(["a"])
        player.play()
        rig.run(for: 2)
        player.pause()
        rig.run(for: 1)
        events = []

        player.play()
        rig.run(for: 2)

        XCTAssertEqual(telemetry, [])
    }

    // MARK: Buffering

    func testOneStallSendsOneBufferingPair() {
        player.setItems(["a"])
        player.play()
        rig.run(for: 3)
        events = []

        rig.output.injectStall()
        rig.run(for: 2)

        XCTAssertEqual(names, ["bufferingStarted", "bufferingEnded"])
        guard case let .bufferingStarted(index, position) = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(index, 0)
        XCTAssertEqual(position, 3, accuracy: 0.25)
        XCTAssertTrue(player.isPlaying)
    }

    func testAPlainPauseSendsNoBufferingEvent() {
        player.setItems(["a"])
        player.play()
        rig.run(for: 3)
        events = []

        player.pause()
        rig.run(for: 2)
        player.play()
        rig.run(for: 2)

        XCTAssertEqual(telemetry, [])
    }

    func testAStallWhilePausedSendsNoBufferingEvent() {
        player.setItems(["a"])
        player.play()
        rig.run(for: 3)
        player.pause()
        rig.run(for: 1)
        events = []

        rig.output.injectStall()
        rig.run(for: 2)

        XCTAssertEqual(telemetry, [])
    }

    func testAPauseDuringAStallEndsIt() {
        player.setItems(["a"])
        player.play()
        rig.run(for: 3)
        events = []

        rig.output.injectStall()
        rig.pump()
        XCTAssertEqual(telemetry, ["bufferingStarted"])

        player.pause()
        rig.run(for: 2)

        XCTAssertEqual(telemetry, ["bufferingStarted", "bufferingEnded"])
    }

    func testASeekDuringAStallEndsItBeforeItsFirstAudio() {
        player.setItems(["a"])
        player.play()
        rig.run(for: 3)
        events = []

        rig.output.injectStall()
        rig.pump()
        player.seek(to: 6)
        rig.run(for: 1)

        XCTAssertEqual(telemetry, ["bufferingStarted", "bufferingEnded", "firstAudioRendered"])
    }

    // MARK: A stall in progress ends exactly once

    private func stallInProgress(_ items: [String] = ["a", "b"], startIndex: Int = 0) {
        player.setItems(items, startIndex: startIndex)
        player.play()
        rig.run(for: 3)
        events = []
        rig.output.injectStall()
        rig.pump()
        XCTAssertEqual(telemetry, ["bufferingStarted"])
    }

    func testStopEndsAStallOnce() {
        stallInProgress()
        player.stop()
        rig.run(for: 2)
        XCTAssertEqual(telemetry, ["bufferingStarted", "bufferingEnded"])
    }

    func testRemoveAllEndsAStallOnce() {
        stallInProgress()
        player.removeAll()
        rig.run(for: 2)
        XCTAssertEqual(telemetry, ["bufferingStarted", "bufferingEnded"])
    }

    func testRemovingTheOnlyItemEndsAStallOnce() {
        stallInProgress(["a"])
        player.remove(at: 0)
        rig.run(for: 2)
        XCTAssertEqual(telemetry, ["bufferingStarted", "bufferingEnded"])
    }

    func testARendererFailureEndsAStallOnce() {
        stallInProgress()
        rig.output.injectFailure()
        rig.run(for: 2)
        XCTAssertEqual(names, ["bufferingStarted", "bufferingEnded", "recoveredPaused"])
    }

    // The stall straddles the end of a, so b's source failing is what moves on and fails the item.
    func testAnItemFailureEndsAStallBeforeItReports() {
        rig.factory.failing = ["b"]
        player.setItems(["a", "b"])
        player.play()
        rig.run(for: 9.5)
        events = []
        rig.output.injectStall()
        rig.pump()
        XCTAssertEqual(telemetry, ["bufferingStarted"])

        rig.run(for: 2)

        XCTAssertEqual(names, ["bufferingStarted", "bufferingEnded", "itemTransition", "itemFailed"])
    }

    func testAnInterruptionEndsAStallOnce() {
        stallInProgress()
        rig.session.interruptionBegan()
        rig.run(for: 2)
        XCTAssertEqual(telemetry, ["bufferingStarted", "bufferingEnded"])
    }

    func testAGaplessTransitionEndsAStallBeforeTheTransition() {
        player.setItems(["a", "b"])
        player.play()
        rig.run(for: 9.5)
        events = []
        rig.output.injectStall()
        rig.pump()
        XCTAssertEqual(telemetry, ["bufferingStarted"])

        rig.run(for: 2)

        XCTAssertEqual(names, ["bufferingStarted", "bufferingEnded", "itemTransition", "firstAudioRendered"])
        XCTAssertEqual(firstAudio.map(\.index), [1])
    }

    // MARK: Seeks and edits

    func testTwoRapidSeeksSendOneFirstAudioAtTheSecondTarget() {
        player.setItems(["a"])
        player.play()
        rig.run(for: 3)
        events = []

        player.seek(to: 6)
        player.seek(to: 8)
        rig.run(for: 2)

        XCTAssertEqual(firstAudio, [PlayerRig.Landing(index: 0, position: 8)])
    }

    func testASeekBeforeFirstAudioSendsOneFirstAudioAtTheTarget() {
        player.setItems(["a"])
        player.play()
        player.seek(to: 5)
        rig.run(for: 2)

        XCTAssertEqual(firstAudio, [PlayerRig.Landing(index: 0, position: 5)])
    }

    func testAPositionFromBeforeASeekSendsNoFirstAudio() {
        player.setItems(["a"])
        player.play()
        rig.run(for: 3)
        let stale = rig.inFlight {
            rig.output.advance(by: 0.25)
            rig.timer.fire()
        }
        events = []

        player.seek(to: 6)
        rig.deliver(stale)
        XCTAssertEqual(firstAudio, [])

        rig.run(for: 2)
        XCTAssertEqual(firstAudio, [PlayerRig.Landing(index: 0, position: 6)])
    }

    func testTheIndexFollowsAnEditBeforeTheCurrentItem() {
        player.setItems(["a", "b"], startIndex: 1)
        player.play()
        player.insert(["c"], at: 0)
        rig.run(for: 3)
        XCTAssertEqual(firstAudio.map(\.index), [2])

        events = []
        player.remove(at: 0)
        rig.output.injectStall()
        rig.pump()
        XCTAssertEqual(names, ["bufferingStarted"])
        guard case let .bufferingStarted(index, _) = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(index, 1)
    }
}
