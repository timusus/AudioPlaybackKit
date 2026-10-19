@testable @_spi(Testing) import PlaybackRender
import XCTest

/// `truncate` cuts what is written at a time so a partial flush can re-feed from there: the map keeps
/// the whole frames before the cut and says which media frame the replacement starts at. Eight frames
/// a second keeps every time exact.
final class MediaPositionMapTruncateTests: XCTestCase {
    private let mono = PCMFormat(sampleRate: 8, channelCount: 1)

    private func tag(_ item: Int, _ mediaStartFrame: Int64, _ frameCount: Int64) -> SegmentTag {
        SegmentTag(item: item, mediaStartFrame: mediaStartFrame, frameCount: frameCount)
    }

    /// Item 0 is 24 frames (3 s) and item 1 is 16 frames (2 s), joined at 3 s.
    private func twoItems() -> MediaPositionMap {
        var map = MediaPositionMap()
        map.append(tag(0, 0, 24), format: mono)
        map.append(tag(1, 0, 16), format: mono)
        return map
    }

    func testACutInsideASegmentKeepsTheWholeFramesBeforeItAndResumesThere() {
        var map = MediaPositionMap()
        map.append(tag(0, 100, 24), format: mono)

        let cut = map.truncate(from: 1.75)

        XCTAssertEqual(cut?.time, 1.75)
        XCTAssertEqual(cut?.resume, .init(item: 0, mediaFrame: 114, sampleRate: 8))
        XCTAssertEqual(map.writtenEnd, 1.75)
    }

    func testACutBetweenFramesRoundsUpSoNothingHeardIsReplaced() {
        var map = MediaPositionMap()
        map.append(tag(0, 0, 24), format: mono)

        let cut = map.truncate(from: 1.8)

        XCTAssertEqual(cut?.time, 1.875)
        XCTAssertEqual(cut?.resume, .init(item: 0, mediaFrame: 15, sampleRate: 8))
        XCTAssertEqual(map.writtenEnd, 1.875)
    }

    func testTheReAppendedFramesJoinTheKeptSegmentSoThePositionIsContinuous() {
        var map = MediaPositionMap()
        map.append(tag(0, 0, 24), format: mono)
        _ = map.truncate(from: 1.75)

        map.append(tag(0, 14, 10), format: mono)

        XCTAssertEqual(map.writtenEnd, 3)
        XCTAssertEqual(map.position(at: 2.5), .init(item: 0, mediaFrame: 20, sampleRate: 8))
    }

    func testACutInsideTheFirstItemDropsTheNextAndResumesInTheFirst() {
        var map = twoItems()

        let cut = map.truncate(from: 2.75)

        XCTAssertEqual(cut?.resume, .init(item: 0, mediaFrame: 22, sampleRate: 8))
        XCTAssertEqual(map.writtenEnd, 2.75)
        map.append(tag(0, 22, 2), format: mono)
        map.append(tag(1, 0, 16), format: mono)
        XCTAssertEqual(map.advance(to: 3), [.item(0, mono), .item(1, mono)])
    }

    func testACutExactlyAtTheJoinResumesAtTheNextItemsFirstFrame() {
        var map = twoItems()

        let cut = map.truncate(from: 3)

        XCTAssertEqual(cut?.time, 3)
        XCTAssertEqual(cut?.resume, .init(item: 1, mediaFrame: 0, sampleRate: 8))
        XCTAssertEqual(map.writtenEnd, 3)
    }

    func testACutInsideTheNextItemKeepsTheFirstAndTheStartOfTheNext() {
        var map = twoItems()
        XCTAssertEqual(map.advance(to: 3.25), [.item(0, mono), .item(1, mono)])

        let cut = map.truncate(from: 3.75)

        XCTAssertEqual(cut?.resume, .init(item: 1, mediaFrame: 6, sampleRate: 8))
        map.append(tag(1, 6, 10), format: mono)
        XCTAssertEqual(map.advance(to: 4), [], "item 1 was already reported once")
        XCTAssertEqual(map.position(at: 4), .init(item: 1, mediaFrame: 8, sampleRate: 8))
    }

    func testACutPastTheWrittenEndHasNothingToReplace() {
        var map = twoItems()

        XCTAssertNil(map.truncate(from: 5.5))
        XCTAssertEqual(map.writtenEnd, 5)
        var empty = MediaPositionMap()
        XCTAssertNil(empty.truncate(from: 1))
    }

    func testAZeroFrameItemAtTheCutIsDroppedAndResumedFrom() {
        var map = MediaPositionMap()
        map.append(tag(0, 0, 16), format: mono)
        map.append(tag(1, 0, 0), format: mono)
        map.append(tag(2, 0, 16), format: mono)

        let cut = map.truncate(from: 2)

        XCTAssertEqual(cut?.resume, .init(item: 1, mediaFrame: 0, sampleRate: 8))
        XCTAssertEqual(map.writtenEnd, 2)
    }

    func testAZeroFrameItemBeforeTheCutIsKept() {
        var map = MediaPositionMap()
        map.append(tag(0, 0, 8), format: mono)
        map.append(tag(1, 0, 0), format: mono)
        map.append(tag(2, 0, 16), format: mono)

        let cut = map.truncate(from: 1.5)

        XCTAssertEqual(cut?.resume, .init(item: 2, mediaFrame: 4, sampleRate: 8))
        XCTAssertEqual(map.advance(to: 1.5), [.item(0, mono), .item(1, mono), .item(2, mono)])
    }
}
