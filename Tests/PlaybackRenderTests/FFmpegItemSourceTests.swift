import Foundation
import PlaybackDecode
@testable @_spi(Testing) import PlaybackRender
import XCTest

/// The duration an `FFmpegItemSource` reports once probed, read by path from the conformance fixtures.
final class FFmpegItemSourceTests: XCTestCase {
    private static let conformance = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PlaybackDecodeConformanceTests")

    /// A file read as a body of unknown length, as a live or chunked HTTP response is.
    private final class UnknownLengthReader: StreamByteReader {
        private let file: FileByteReader
        init(_ file: FileByteReader) { self.file = file }
        var totalLength: Int64? { nil }
        var position: Int64 { file.position }
        func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
            try file.read(into: buffer, maxLength: maxLength)
        }
        func seek(to offset: Int64) throws { try file.seek(to: offset) }
        func cancel() { file.cancel() }
        func interrupt() { file.interrupt() }
        func clearInterrupt() { file.clearInterrupt() }
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(FFmpegStreamDecoder.isAvailable, "this build has no FFmpeg xcframework")
    }

    private func file(_ path: String) throws -> FileByteReader {
        try FileByteReader(url: Self.conformance.appendingPathComponent(path))
    }

    func testTheDurationIsTheContainersInFramesOnceOpened() throws {
        // The Info frame counts 461 MPEG frames of 1152 samples.
        let source = FFmpegItemSource(reader: try file("SeekFixtures/cbr_128k_unpadded_info.mp3"))
        XCTAssertNil(source.frameCount)
        _ = try source.open()
        XCTAssertEqual(source.frameCount, 461 * 1152)
    }

    func testABodyOfUnknownLengthWithNoSeekTableHasNoDuration() throws {
        let reader = UnknownLengthReader(try file("Fixtures/bear-cbr-no-seek-table-trailing-garbage.mp3"))
        let source = FFmpegItemSource(reader: reader)
        _ = try source.open()
        XCTAssertNil(source.frameCount)
    }

    func testReleaseCancelsTheReader() throws {
        let reader = try file("SeekFixtures/cbr_128k_unpadded_info.mp3")
        let source = FFmpegItemSource(reader: reader)
        _ = try source.open()

        source.release()

        var byte: UInt8 = 0
        XCTAssertThrowsError(try reader.read(into: &byte, maxLength: 1)) {
            XCTAssertEqual($0 as? StreamByteReaderError, .cancelled)
        }
    }
}
