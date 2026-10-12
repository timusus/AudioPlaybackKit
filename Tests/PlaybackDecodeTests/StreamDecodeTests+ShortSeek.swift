import Foundation
import XCTest

@testable import PlaybackDecode

/// Stands in for a growing download: bytes before `frontier` are fetched, the rest are not. A read
/// never runs past the frontier (a download would block there), so reaching unfetched bytes by
/// reading forward, rather than by a seek the source could have answered with a new range, is seen.
private final class FrontierByteReader: StreamByteReader {
    private let inner: FileByteReader
    private let lock = NSLock()
    private var frontierOffset: Int64?
    private var seekedPastFrontier = false
    private(set) var readForwardPastFrontier = false
    private(set) var seeksPastFrontier: [Int64] = []

    init(_ inner: FileByteReader) { self.inner = inner }

    func setFrontier(_ offset: Int64) {
        lock.lock(); defer { lock.unlock() }
        frontierOffset = offset
    }

    var totalLength: Int64? { inner.totalLength }
    var position: Int64 { inner.position }

    var fetchedEnd: Int64? {
        lock.lock(); defer { lock.unlock() }
        return frontierOffset.map { max($0, inner.position) }
    }

    func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        var limit = maxLength
        if let frontier = frontierOffset, !seekedPastFrontier {
            let pos = inner.position
            if pos >= frontier {
                readForwardPastFrontier = true
            } else {
                limit = min(limit, Int(frontier - pos))
            }
        }
        return try inner.read(into: buffer, maxLength: limit)
    }

    func seek(to offset: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        if let frontier = frontierOffset {
            seekedPastFrontier = offset >= frontier
            if seekedPastFrontier { seeksPastFrontier.append(offset) }
        }
        try inner.seek(to: offset)
    }

    func cancel() { inner.cancel() }

    func interrupt() { inner.interrupt() }

    func clearInterrupt() { inner.clearInterrupt() }
}

extension StreamDecodeTests {
    // MARK: - A short forward seek past the fetched bytes

    /// A target a few seconds past what a growing source has fetched lies inside AVIO's short-seek
    /// window (its buffer plus 32 KiB), which it serves by reading forward through the open
    /// connection at network rate. The source has to be asked for the target instead, so it can
    /// open a range there.
    func testAShortSeekPastTheFetchedBytesSeeksTheSource() throws {
        try skipUnlessAvailable()
        for name in [Fixture.mp3, Fixture.moovFirst] {
            let url = try Fixture.url(name)
            let file = try FileByteReader(url: url)
            let fileSize = try XCTUnwrap(file.totalLength)
            let reader = FrontierByteReader(file)
            let decoder = FFmpegStreamDecoder(reader: reader)
            let format = try decoder.open()
            var frames = 0
            while frames < Int(format.sampleRate) / 2, let chunk = decoder.nextChunk() {
                frames += chunk.count / format.channelCount
            }

            let frontier = reader.position
            reader.setFrontier(frontier)
            let bytesPerSecond = Double(fileSize) / (Double(Fixture.frameCount) / format.sampleRate)
            let target = Double(frontier + 24 * 1024) / bytesPerSecond
            XCTAssertLessThan(target, 18, "\(name): the fixture is too short for this seek")

            let landed = try decoder.seek(toSeconds: target)
            XCTAssertEqual(landed, target, accuracy: 0.001, "\(name)")
            XCTAssertNotNil(decoder.nextChunk(), "\(name): no audio after the seek")
            XCTAssertFalse(reader.readForwardPastFrontier,
                           "\(name): the seek to \(target) s read forward past the fetched bytes (\(frontier))")
            XCTAssertFalse(reader.seeksPastFrontier.isEmpty, "\(name): the source never saw the seek")
        }
    }
}
