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
}
