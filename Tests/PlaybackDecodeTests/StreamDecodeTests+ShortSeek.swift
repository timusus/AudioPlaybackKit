import Foundation
import XCTest
@testable import PlaybackDecode

/// Stands in for a growing download: bytes before `frontier` are fetched, the rest are not, until a
/// seek past the frontier opens a range there that fetches the rest at once. A read never runs into
/// the gap (a download would block there), so reaching unfetched bytes by reading forward, rather
/// than by a seek the source could have answered with a new range, is seen.
private final class FrontierByteReader: StreamByteReader {
    private let inner: FileByteReader
    private let lock = NSLock()
    private var frontierOffset: Int64?
    private var rangeOpenedAt: Int64?
    private var readsIntoTheGap = false
    private var seekLog: [Int64] = []

    init(_ inner: FileByteReader) { self.inner = inner }

    /// Where every reader seek since the frontier was set went.
    var seeks: [Int64] {
        lock.lock(); defer { lock.unlock() }
        return seekLog
    }

    var readForwardPastFrontier: Bool {
        lock.lock(); defer { lock.unlock() }
        return readsIntoTheGap
    }

    func setFrontier(_ offset: Int64) {
        lock.lock(); defer { lock.unlock() }
        frontierOffset = offset
    }

    var totalLength: Int64? { inner.totalLength }
    var position: Int64 { inner.position }

    var fetchedEnd: Int64? {
        lock.lock(); defer { lock.unlock() }
        guard let frontier = frontierOffset else { return nil }
        let pos = inner.position
        if pos < frontier { return frontier }
        if let opened = rangeOpenedAt, pos >= opened { return inner.totalLength }
        return pos
    }

    func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var limit = maxLength
        if let frontier = frontierOffset {
            let pos = inner.position
            if pos < frontier {
                limit = min(limit, Int(frontier - pos))
            } else if rangeOpenedAt.map({ pos < $0 }) ?? true {
                readsIntoTheGap = true
            }
        }
        return try inner.read(into: buffer, maxLength: limit)
    }

    func seek(to offset: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        if let frontier = frontierOffset {
            seekLog.append(offset)
            if offset >= frontier, rangeOpenedAt.map({ offset < $0 }) ?? true { rangeOpenedAt = offset }
        }
        try inner.seek(to: offset)
    }

    func cancel() { inner.cancel() }

    func interrupt() { inner.interrupt() }

    func clearInterrupt() { inner.clearInterrupt() }
}

extension StreamDecodeTests {

    // MARK: - A short forward seek past the fetched bytes

    /// `tone.mp3` is 64 kbps CBR (8000 bytes a second) whose audio starts at byte 313, after a
    /// 105-byte ID3v2 tag and a 208-byte Info frame.
    private static let toneBytesPerSecond = 8000.0
    private static let toneAudioStart: Int64 = 313

    /// Opens `tone.mp3`, decodes half a second, marks what has been read as all that is fetched, and
    /// makes a seek about 24 KiB past it: inside AVIO's short-seek window (its buffer plus 32 KiB).
    private func seekShortlyPastTheFetchedBytes() throws -> (FFmpegStreamDecoder, FrontierByteReader, Double) {
        let reader = FrontierByteReader(try FileByteReader(url: try Fixture.url(Fixture.mp3)))
        let decoder = FFmpegStreamDecoder(reader: reader)
        let format = try decoder.open()
        var frames = 0
        while frames < Int(format.sampleRate) / 2, let chunk = decoder.nextChunk() {
            frames += chunk.count / format.channelCount
        }
        let frontier = reader.position
        reader.setFrontier(frontier)
        let target = Double(frontier - Self.toneAudioStart + 24 * 1024) / Self.toneBytesPerSecond
        XCTAssertLessThan(target, 18, "the fixture is too short for this seek")

        let landed = try decoder.seek(toSeconds: target)
        XCTAssertEqual(landed, target, accuracy: 0.001)
        XCTAssertNotNil(decoder.nextChunk(), "no audio after the seek")
        return (decoder, reader, target)
    }

    /// AVIO serves a target inside its short-seek window by reading forward through the open
    /// connection at network rate. The source has to be asked for the target instead, so it can
    /// open a range there: one reader seek, landing a pre-roll (a few frames) before the target.
    func testAShortSeekPastTheFetchedBytesSeeksTheSourceToTheTarget() throws {
        try skipUnlessAvailable()
        let (_, reader, target) = try seekShortlyPastTheFetchedBytes()

        XCTAssertFalse(reader.readForwardPastFrontier, "the seek to \(target) s read forward past the fetched bytes")
        XCTAssertEqual(reader.seeks.count, 1, "the source saw \(reader.seeks), not one seek")
        let targetByte = Self.toneAudioStart + Int64(target * Self.toneBytesPerSecond)
        let seek = try XCTUnwrap(reader.seeks.first)
        XCTAssertLessThanOrEqual(seek, targetByte, "the source was sent past the target")
        XCTAssertGreaterThan(seek, targetByte - 2048, "the source was sent \(targetByte - seek) bytes before the target")
    }

    /// The jump is one reposition: once the source holds the bytes ahead, a further short seek
    /// reads forward through AVIO's buffer rather than reaching the source as another seek.
    func testASeekInsideTheFetchedBytesAfterAShortSeekStaysInTheBuffer() throws {
        try skipUnlessAvailable()
        let (decoder, reader, target) = try seekShortlyPastTheFetchedBytes()
        let seeksBefore = reader.seeks

        let next = target + 1
        let landed = try decoder.seek(toSeconds: next)
        XCTAssertEqual(landed, next, accuracy: 0.001)
        XCTAssertNotNil(decoder.nextChunk(), "no audio after the second seek")
        XCTAssertEqual(reader.seeks, seeksBefore, "a seek inside the fetched bytes reached the source")
    }
}
