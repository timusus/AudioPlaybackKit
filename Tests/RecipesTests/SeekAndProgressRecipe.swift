import PlaybackDecode
import PlaybackPlayer
import PlaybackPlayerTestSupport
import XCTest

final class SeekAndProgressRecipe: XCTestCase {
    // The decoder: believe `landed`, not the target.
    func testASeekReturnsWhereItLanded() throws {
        let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: try writeWAV(seconds: 4)))
        _ = try decoder.open()

        let landed = try decoder.seek(toSeconds: 2.5)

        XCTAssertEqual(landed, 2.5, accuracy: 0.001)
        var frames = 0
        while let chunk = decoder.nextChunk() { frames += chunk.count }
        XCTAssertEqual(frames, Int(1.5 * 8000))
    }
}

@MainActor
final class PlayerSeekRecipe: XCTestCase {
    private let factory = FakeItemFactory<Track>()    // ten seconds per item at 8 Hz
    private func makeRig() -> PlayerTestRig<Track> {
        let factory = factory
        return PlayerTestRig { try factory.make($0) }
    }

    func testPositionAdvancesWhilePlayingAndSeeksLand() {
        let rig = makeRig()
        var landed: [(index: Int, position: TimeInterval)] = []
        rig.onEvent = { if case let .seekLanded(index, position) = $0 { landed.append((index, position)) } }
        rig.player.setItems([Track(id: 1), Track(id: 2)])
        rig.player.play()
        rig.run(for: 2)
        XCTAssertEqual(rig.player.position, 2, accuracy: 0.3)

        rig.player.seek(to: 6)
        rig.run(for: 1)
        XCTAssertEqual(landed.map(\.position), [6])
        XCTAssertEqual(rig.player.position, 7, accuracy: 0.3)

        // Relative seeks clamp to the item; across items needs the index.
        rig.player.seek(by: -100)
        rig.run(for: 1)
        XCTAssertEqual(rig.player.position, 1, accuracy: 0.3)
        rig.player.seek(to: 4, itemAt: 1)
        rig.run(for: 1)
        XCTAssertEqual(rig.player.currentIndex, 1)
        XCTAssertEqual(rig.player.position, 5, accuracy: 0.3)
    }

    // A source that cannot land on the target says so, and `position` is where it did land.
    func testAnAdjustedSeekReportsWhereItLanded() {
        factory.coarseSeeks = [Track(id: 1)]        // lands on the whole second before, as at a keyframe
        let rig = makeRig()
        var adjusted: [(requested: TimeInterval, position: TimeInterval)] = []
        rig.onEvent = { if case let .seekAdjusted(_, requested, position) = $0 { adjusted.append((requested, position)) } }
        rig.player.setItems([Track(id: 1)])
        rig.player.play()
        rig.run(for: 1)

        rig.player.seek(to: 5.5)
        rig.run(for: 1)

        XCTAssertEqual(adjusted.map(\.requested), [5.5])
        XCTAssertEqual(adjusted.map(\.position), [5])
    }

    // A live or unseekable item refuses: the UI disables its slider from `isSeekable`.
    func testAnUnseekableItemStaysWhereItIs() {
        factory.live = [Track(id: 1)]
        let rig = makeRig()
        rig.player.setItems([Track(id: 1)])
        rig.player.play()
        rig.run(for: 2)

        XCTAssertFalse(rig.player.isSeekable)
        XCTAssertNil(rig.player.duration)
        let before = rig.player.position
        rig.player.seek(to: 8)
        rig.run(for: 1)
        XCTAssertEqual(rig.player.position, before + 1, accuracy: 0.3)
    }
}
