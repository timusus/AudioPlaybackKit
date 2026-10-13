import XCTest
@_spi(Testing) @testable import PlaybackPlayer

/// An event names the item it was sent for, read from `events` after the list changed (#180).
@MainActor
final class PlayerEventItemTests: XCTestCase {
    private var rig: PlayerRig!
    private var player: Player<String> { rig.player }

    override func setUp() async throws {
        rig = PlayerRig()
    }

    func testATransitionReadAfterAnEqualLengthSetItemsNamesItsItems() async {
        player.setItems(["a", "b"])
        player.play()
        rig.run(for: 11)
        player.setItems(["c", "d"])

        let events = await rig.finish()

        let transitions: [(PlayerEvent<String>.ItemRef?, PlayerEvent<String>.ItemRef?)] = events.compactMap {
            guard case let .itemTransition(from, to, _) = $0 else { return nil }
            return (from, to)
        }
        XCTAssertEqual(transitions.first?.0, .init(index: 0, item: "a"))
        XCTAssertEqual(transitions.first?.1, .init(index: 1, item: "b"))
        let firstAudio: [PlayerEvent<String>.ItemRef] = events.compactMap {
            guard case let .firstAudioRendered(ref, _) = $0 else { return nil }
            return ref
        }
        XCTAssertEqual(firstAudio.prefix(2), [.init(index: 0, item: "a"), .init(index: 1, item: "b")])
    }

    func testAFailureReadAfterAShorterReplaceItemsNamesItsItem() async {
        rig.factory.failing = ["b"]
        player.setItems(["a", "b"])
        player.play()
        rig.run(for: 11)
        player.replaceItems(["c"], currentIndex: 0)

        let events = await rig.finish()

        let failed: [PlayerEvent<String>.ItemRef] = events.compactMap {
            guard case let .itemFailed(ref, _) = $0 else { return nil }
            return ref
        }
        XCTAssertEqual(failed, [.init(index: 1, item: "b")])
    }

    func testRemovingTheCurrentItemSendsItAsFrom() {
        var transitions: [(PlayerEvent<String>.ItemRef?, PlayerEvent<String>.ItemRef?)] = []
        player.onEvent = {
            if case let .itemTransition(from, to, _) = $0 { transitions.append((from, to)) }
        }
        player.setItems(["a", "b", "c"], startIndex: 1)
        player.play()
        rig.run(for: 1)

        player.remove(at: 1)

        XCTAssertEqual(transitions.count, 1)
        XCTAssertEqual(transitions.first?.0, .init(index: 1, item: "b"))
        XCTAssertEqual(transitions.first?.1, .init(index: 1, item: "c"))
    }
}
