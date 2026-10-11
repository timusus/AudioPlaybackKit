import Foundation
import PlaybackRender
import XCTest
@_spi(Testing) @testable import PlaybackPlayer

/// The player's state, position and seeks on the fake output: items are ten seconds at 8 Hz, and
/// each item's samples start at its own base (a 0, b 1000, ...).
@MainActor
final class PlayerCoreTests: XCTestCase {
    private var rig: PlayerRig!
    private var player: Player<String> { rig.player }

    override func setUp() async throws {
        rig = PlayerRig()
    }

    func testSetItemsArmsTheCurrentThenTheNextInTheFactorysCallOrder() {
        player.setItems(["a", "b", "c"])

        XCTAssertEqual(rig.factory.calls, ["a", "b"])
        XCTAssertEqual(player.items, ["a", "b", "c"])
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(player.currentItem, "a")
        rig.pump()
        XCTAssertEqual(rig.firstSampleWritten(skipping: 0), 0)
    }

    func testSetItemsStartsAtTheGivenIndexAndPosition() {
        player.setItems(["a", "b", "c"], startIndex: 1, startPosition: 2)

        XCTAssertEqual(rig.factory.calls, ["b", "c"])
        XCTAssertEqual(player.currentIndex, 1)
        XCTAssertEqual(player.position, 2)
        rig.pump()
        XCTAssertEqual(rig.firstSampleWritten(skipping: 0), 1016)
        XCTAssertEqual(player.position, 2)
    }

    func testStateFollowsTheTransportStatus() {
        XCTAssertEqual(player.state, .idle)
        player.setItems(["a"])
        rig.settle()
        XCTAssertEqual(player.state, .ready, "paused with an item")

        player.play()
        rig.settle()
        XCTAssertEqual(player.state, .buffering, "decode behind the clock")
        rig.pump()
        XCTAssertEqual(player.state, .ready)

        player.pause()
        rig.settle()
        XCTAssertEqual(player.state, .ready)

        player.play()
        rig.run(for: 11)
        XCTAssertEqual(player.state, .ended)
    }

    // #134: on the phone each transport event can land in its own drain, and a resume flickered
    // `isPlaying` true, false, true, with the lock screen's rate following it.
    func testAResumeWithAudioQueuedKeepsIsPlayingThroughEveryEvent() {
        player.setItems(["a"])
        player.play()
        rig.run(for: 1)
        player.pause()
        rig.settle()

        let events = rig.inFlight { player.play() }
        XCTAssertTrue(player.isPlaying)
        XCTAssertFalse(events.isEmpty)
        for event in events {
            rig.deliver([event])
            XCTAssertTrue(player.isPlaying, "after \(event)")
        }
    }

    func testPlayWhenReadyIsUnchangedByTransportEvents() {
        player.setItems(["a"])
        XCTAssertFalse(player.playWhenReady)
        rig.run(for: 1)
        XCTAssertFalse(player.playWhenReady)

        player.playWhenReady = true
        rig.run(for: 11)
        XCTAssertEqual(player.state, .ended)
        XCTAssertTrue(player.playWhenReady)
    }

    func testPositionInSecondsFollowsTheClockOnEveryPump() {
        player.setItems(["a"])
        player.play()
        var positions: [TimeInterval] = []
        for _ in 0..<5 {
            rig.pump()
            positions.append(player.position)
            rig.output.advance(by: 0.25)
        }

        XCTAssertEqual(positions, [0, 0.25, 0.5, 0.75, 1])
    }

    func testDurationArrivesAfterOpen() {
        player.setItems(["a"])
        XCTAssertNil(player.duration)
        rig.pump()
        XCTAssertEqual(player.duration, 10)
        XCTAssertFalse(player.isLive)
    }

    func testALiveItemHasNoDurationAndIgnoresSeeks() {
        rig.factory.live = ["a"]
        player.setItems(["a"])
        rig.pump()
        XCTAssertNil(player.duration)
        XCTAssertTrue(player.isLive)

        let flushes = rig.output.flushes.count
        player.seek(to: 5)
        rig.pump()
        XCTAssertEqual(rig.output.flushes.count, flushes)
        XCTAssertEqual(player.position, 0)
    }

    func testSeekWithinTheItem() {
        player.setItems(["a", "b"])
        player.play()
        rig.run(for: 1)
        let written = rig.output.enqueues.count

        player.seek(to: 5)
        rig.pump()

        XCTAssertEqual(rig.firstSampleWritten(skipping: written), 40)
        XCTAssertEqual(player.position, 5)
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(rig.factory.calls, ["a", "b"])
    }

    func testSeekToTheArmedNextReusesItsSourceAndArmsTheOneAfter() async {
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 1)
        let written = rig.output.enqueues.count

        player.seek(to: 2, itemAt: 1)
        XCTAssertEqual(player.currentIndex, 1)
        XCTAssertEqual(rig.factory.calls, ["a", "b", "c"])
        rig.pump()

        XCTAssertEqual(rig.firstSampleWritten(skipping: written), 1016)
        XCTAssertEqual(player.position, 2)
        XCTAssertEqual(player.duration, 10)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [.init(from: 0, to: 1, reason: .seek)])
    }

    func testSeekToALaterAndAnEarlierItemSetsItCurrent() async {
        player.setItems(["a", "b", "c", "d"])
        player.play()
        rig.run(for: 1)
        var written = rig.output.enqueues.count

        player.seek(to: 0, itemAt: 2)
        XCTAssertEqual(rig.factory.calls, ["a", "b", "c", "d"])
        XCTAssertEqual(player.currentItem, "c")
        rig.pump()
        XCTAssertEqual(rig.firstSampleWritten(skipping: written), 2000)
        written = rig.output.enqueues.count

        player.seek(to: 1, itemAt: 0)
        XCTAssertEqual(rig.factory.calls, ["a", "b", "c", "d", "a", "b"])
        XCTAssertEqual(player.currentItem, "a")
        rig.pump()
        XCTAssertEqual(rig.firstSampleWritten(skipping: written), 8)
        XCTAssertEqual(player.position, 1)

        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [
            .init(from: 0, to: 2, reason: .seek),
            .init(from: 2, to: 0, reason: .seek),
        ])
    }

    func testAPositionStillInFlightForTheItemBeforeASeekIsIgnored() {
        player.setItems(["a", "b", "c"])
        player.play()
        rig.run(for: 1)
        rig.output.advance(by: 0.25)
        rig.timer.fire()

        player.seek(to: 3, itemAt: 2)
        XCTAssertEqual(player.position, 3)
        rig.player.drainTransportEvents()
        XCTAssertEqual(player.position, 3, "a's 1.25 s arrived after c became current")
        rig.pump()
        XCTAssertEqual(player.position, 3)
    }

    func testSeekByClampsToTheItem() {
        player.setItems(["a"])
        rig.pump()
        player.seek(by: 3)
        rig.pump()
        XCTAssertEqual(player.position, 3)

        // Unclamped, -2 s would trip the transport's precondition.
        player.seek(by: -5)
        rig.pump()
        XCTAssertEqual(player.position, 0)

        player.seek(by: 100)
        rig.pump()
        XCTAssertEqual(player.state, .ended)
        XCTAssertEqual(player.currentIndex, 0)
    }

    func testSkipToNextAndPrevious() {
        player.setItems(["a", "b"])
        XCTAssertTrue(player.hasNext)
        XCTAssertFalse(player.hasPrevious)

        player.skipToNext()
        XCTAssertEqual(player.currentIndex, 1)
        XCTAssertFalse(player.hasNext)
        XCTAssertTrue(player.hasPrevious)
        player.skipToNext()
        XCTAssertEqual(player.currentIndex, 1)

        player.skipToPrevious()
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(rig.factory.calls, ["a", "b", "a", "b"])
    }

    func testRateAndVolumeReachTheOutput() {
        player.setItems(["a"])
        player.play()
        rig.pump()

        player.rate = 2
        rig.settle()
        XCTAssertEqual(rig.output.rate, 2)
        player.rate = 10
        rig.settle()
        XCTAssertEqual(player.rate, 4)
        XCTAssertEqual(rig.output.rate, 4)
        player.rate = 0.1
        XCTAssertEqual(player.rate, 0.25)

        player.volume = 0.5
        rig.settle()
        XCTAssertEqual(rig.output.volume, 0.5)
        player.volume = 2
        rig.settle()
        XCTAssertEqual(player.volume, 1)
        XCTAssertEqual(rig.output.volume, 1)
    }

    func testProcessorsReachTheTransport() {
        player.setProcessors([Negate()])
        player.setItems(["b"])
        rig.pump()

        XCTAssertEqual(rig.output.enqueues.first?.samples, [-1000, -1001])
    }

    func testIsPlayingOnlyWhenReadyIntendedAndNotSuppressed() {
        for state in [PlaybackState.idle, .buffering, .ready, .ended] {
            for intent in [false, true] {
                for suppression in [PlaybackSuppression.none, .interruption] {
                    XCTAssertEqual(
                        Player<String>.isPlaying(state: state, playWhenReady: intent, suppression: suppression),
                        state == .ready && intent && suppression == .none,
                        "\(state) \(intent) \(suppression)"
                    )
                }
            }
        }
    }

    func testACurrentItemThatFailsToOpenIsIdleWithAnErrorAndPlayRetries() async {
        rig.factory.failing = ["a"]
        player.setItems(["a", "b"])
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(player.error?.kind, .source)
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(rig.factory.calls, ["a"])

        rig.factory.failing = []
        player.play()
        XCTAssertNil(player.error)
        XCTAssertEqual(rig.factory.calls, ["a", "a", "b"])
        rig.pump()
        XCTAssertEqual(player.state, .ready)
        XCTAssertTrue(player.playWhenReady)

        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.failedIndices(events), [0])
    }

    func testStopIsIdleKeepsTheItemsAndPlayResumesFromThePosition() {
        player.setItems(["a"])
        player.play()
        rig.run(for: 2)

        player.stop()
        rig.pump()
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(player.items, ["a"])
        XCTAssertEqual(player.position, 2)

        let written = rig.output.enqueues.count
        player.play()
        rig.pump()
        XCTAssertEqual(rig.factory.calls, ["a", "a"])
        XCTAssertEqual(rig.firstSampleWritten(skipping: written), 16)
        XCTAssertEqual(player.state, .ready)
    }
}

/// Negates every sample, so audio that went through it is recognisable.
private final class Negate: AudioProcessor, @unchecked Sendable {
    private var held: [Float] = []
    private var ended = false

    func configure(_ input: PCMFormat) throws -> PCMFormat { input }
    var isActive: Bool { true }
    func queueInput(_ samples: [Float]) { held += samples.map { -$0 } }

    func getOutput() -> ProcessorOutput {
        defer { held = [] }
        return ProcessorOutput(samples: held)
    }

    func queueEndOfStream() { ended = true }
    var isEnded: Bool { ended && held.isEmpty }
    func flush() { held = [] }
    func reset() { held = []; ended = false }
}
