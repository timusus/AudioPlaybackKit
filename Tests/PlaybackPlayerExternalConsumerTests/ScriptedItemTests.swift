import Foundation
import PlaybackPlayer
import PlaybackPlayerTestSupport
import PlaybackRender
import XCTest

/// The scripted factory and the live event tap, as an app's test reaches them: public API only.
@MainActor
final class ScriptedItemTests: XCTestCase {
    private let factory = FakeItemFactory<Episode>()

    private func makeRig() -> PlayerTestRig<Episode> {
        let factory = factory
        return PlayerTestRig { try factory.make($0) }
    }

    func testTheTapSeesAFailureWhileItHappens() async {
        let rig = makeRig()
        factory.unopenable = [Episode(id: 2)]
        var seen: [PlayerEvent<Episode>] = []
        rig.onEvent = { seen.append($0) }
        rig.player.setItems([Episode(id: 1), Episode(id: 2)])
        rig.player.play()

        rig.run(for: 11)
        XCTAssertEqual(rig.player.error?.kind, .source)
        let failed = seen.compactMap { if case let .itemFailed(index, _) = $0 { index } else { nil } }
        XCTAssertEqual(failed, [1])
        let all = await rig.finish()
        XCTAssertEqual(all.count, seen.count)
    }

    func testAFailingSeekThrowsOnlyWhenItWouldMove() throws {
        factory.failingSeeks = [Episode(id: 1)]
        let source = try factory.make(Episode(id: 1))
        _ = try source.open()
        XCTAssertEqual(try source.seek(toFrame: 0), 0)
        XCTAssertThrowsError(try source.seek(toFrame: 16)) {
            XCTAssertEqual($0 as? FakeItemError<Episode>, FakeItemError(item: Episode(id: 1)))
        }
    }

    func testAnItemEndingEarlyStillDeclaresItsLength() throws {
        factory.endingAtFrame = [Episode(id: 1): 41]
        let source = try factory.make(Episode(id: 1))
        _ = try source.open()
        var frames = 0
        while let chunk = try source.nextChunk() { frames += chunk.count }
        XCTAssertEqual(frames, 41)
        XCTAssertEqual(source.duration, 80)
    }

    func testAnItemFailingMidwayKeepsItsDurationAndSeekability() throws {
        factory.failingAtFrame = [Episode(id: 1): 40]
        factory.unknownLength = [Episode(id: 1)]
        let source = try factory.make(Episode(id: 1))
        _ = try source.open()
        XCTAssertNil(source.duration)
        XCTAssertTrue(source.isSeekable)
        XCTAssertEqual(try source.seek(toFrame: 40), 40)
        XCTAssertThrowsError(try source.nextChunk())
    }

    func testAStalledOpenHoldsUntilInterrupted() throws {
        let stall = SourceStall(frame: nil)
        factory.stalls = [Episode(id: 1): stall]
        let source = try factory.make(Episode(id: 1))
        source.begin(epoch: 3)
        let opened = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? source.open()
            opened.signal()
        }

        stall.entered.wait()
        XCTAssertTrue(stall.hasStalled)
        source.interrupt(through: 2)
        XCTAssertEqual(opened.wait(timeout: .now() + 0.2), .timedOut, "an earlier epoch's interrupt leaves it held")
        source.interrupt(through: 3)
        XCTAssertEqual(opened.wait(timeout: .now() + 5), .success)
    }
}
