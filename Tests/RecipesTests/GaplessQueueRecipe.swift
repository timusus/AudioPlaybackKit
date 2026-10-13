import PlaybackPlayer
import PlaybackPlayerTestSupport
import PlaybackRender
import PlaybackRenderTestSupport
import XCTest

@MainActor
final class GaplessQueueRecipe: XCTestCase {
    // The player arms the next item itself, so the app only hands over the list.
    func testAQueuePlaysThroughItsItemsWithoutAGap() {
        let factory = FakeItemFactory<Track>()    // ten seconds per item at 8 Hz
        let rig = PlayerTestRig<Track> { try factory.make($0) }
        var transitions: [(from: Int?, to: Int?, reason: TransitionReason)] = []
        rig.onEvent = {
            if case let .itemTransition(from, to, reason) = $0 { transitions.append((from, to, reason)) }
        }

        rig.player.setItems([Track(id: 1), Track(id: 2), Track(id: 3)])
        rig.player.play()
        rig.run(for: 31)

        XCTAssertEqual(transitions.map(\.to), [1, 2])
        XCTAssertEqual(transitions.map(\.reason), [.auto, .auto])
        XCTAssertEqual(rig.player.state, .ended)
        // Heard audio is one run: a join that left a hole would play silence between the items.
        let silences = rig.output.played.filter { if case .silence = $0 { true } else { false } }
        XCTAssertTrue(silences.isEmpty, "\(silences)")
    }

    // Items of different sample rates join in the same stream.
    func testItemsAtDifferentSampleRatesJoinGaplessly() {
        let factory = FakeItemFactory<Track>()
        factory.formats[Track(id: 2)] = PCMFormat(sampleRate: 16, channelCount: 1)
        factory.lengths[Track(id: 2)] = 160
        let rig = PlayerTestRig<Track> { try factory.make($0) }

        rig.player.setItems([Track(id: 1), Track(id: 2)])
        rig.player.play()
        rig.run(for: 21)

        XCTAssertEqual(rig.player.state, .ended)
        XCTAssertEqual(rig.player.currentIndex, 1)
        let rates = Set(rig.output.enqueues.map(\.format.sampleRate))
        XCTAssertEqual(rates, [8, 16])
    }

    // The queue changes while playing: tell the player, or it keeps a stale next item armed.
    func testEditingTheQueueRearmsTheNextItem() {
        let factory = FakeItemFactory<Track>()
        let rig = PlayerTestRig<Track> { try factory.make($0) }
        rig.player.setItems([Track(id: 1), Track(id: 2)])
        rig.player.play()
        rig.run(for: 2)

        rig.player.replaceItems([Track(id: 1), Track(id: 3)], currentIndex: 0)
        rig.run(for: 9)

        XCTAssertEqual(rig.player.currentItem, Track(id: 3))
    }
}
