import Foundation
import XCTest

@testable import PlaybackDecode

/// A file whose reads fail with `error` from byte `failAt` on, as a source that drops part way.
private final class FailingByteReader: StreamByteReader {
    private let inner: FileByteReader
    private let failAt: Int64
    private let error: Error

    init(url: URL, failAt: Int64, error: Error) throws {
        inner = try FileByteReader(url: url)
        self.failAt = failAt
        self.error = error
    }

    var totalLength: Int64? { inner.totalLength }
    var position: Int64 { inner.position }

    func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
        let left = failAt - inner.position
        guard left > 0 else { throw error }
        return try inner.read(into: buffer, maxLength: min(maxLength, Int(left)))
    }

    func seek(to offset: Int64) throws { try inner.seek(to: offset) }
    func cancel() { inner.cancel() }
    func interrupt() { inner.interrupt() }
    func clearInterrupt() { inner.clearInterrupt() }
}

/// Each failure reaches the caller with the category a player acts on, not one status for all.
final class StreamDecodeErrorCategoryTests: XCTestCase {

    private func temporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Opens, then reads to the end; the error the read failed with, or nil at a clean end.
    private func readFailure(_ reader: StreamByteReader) throws -> StreamDecoderError? {
        let decoder = FFmpegStreamDecoder(reader: reader)
        try decoder.open()
        while decoder.nextChunk() != nil {}
        XCTAssertEqual(decoder.error == nil, decoder.endReason != .failure)
        return decoder.error
    }

    private func failure(_ error: StreamDecoderError?, file: StaticString = #filePath, line: UInt = #line) -> StreamFailure? {
        guard case let .failed(failure)? = error else {
            XCTFail("expected .failed, got \(String(describing: error))", file: file, line: line)
            return nil
        }
        return failure
    }

    func testAPageWhereAudioShouldBeFailsTheOpenAsUnsupported() throws {
        try XCTSkipUnless(FFmpegStreamDecoder.isAvailable, "this build has no FFmpeg xcframework")
        let page = Data(String(repeating: "<html><body>Not found</body></html>\n", count: 400).utf8)
        let reader = try FileByteReader(url: temporaryFile(page))
        XCTAssertThrowsError(try FFmpegStreamDecoder(reader: reader).open()) { error in
            XCTAssertEqual((error as? StreamDecoderError)?.category, .unsupported, "\(error)")
        }
    }

    /// The reader's own failure arrives unchanged, whatever status the C side surfaced it as.
    func testAReaderFailureKeepsItsCategoryThroughTheDecoder() throws {
        try XCTSkipUnless(FFmpegStreamDecoder.isAvailable, "this build has no FFmpeg xcframework")
        let url = try Fixture.url(Fixture.mp3)
        let http = StreamByteReaderError.failed(StreamFailure(.http(status: 503), detail: "status=503"))
        let fromHTTP = try failure(readFailure(FailingByteReader(url: url, failAt: 40_000, error: http)))
        XCTAssertEqual(fromHTTP?.category, .http(status: 503))
        XCTAssertEqual(fromHTTP?.detail, "status=503")

        let dropped = try failure(readFailure(FailingByteReader(url: url, failAt: 40_000, error: URLError(.networkConnectionLost))))
        XCTAssertEqual(dropped?.category, .network)
        XCTAssertEqual(dropped?.urlError?.code, .networkConnectionLost)

        let disk = try failure(readFailure(FailingByteReader(url: url, failAt: 40_000, error: CocoaError(.fileReadUnknown))))
        XCTAssertEqual(disk?.category, .io, "an app reader's own error counts as local I/O")
    }

    func testAReaderFailureDuringTheOpenKeepsItsCategory() throws {
        try XCTSkipUnless(FFmpegStreamDecoder.isAvailable, "this build has no FFmpeg xcframework")
        let lost = StreamByteReaderError.failed(StreamFailure(.network, detail: "idle"))
        let reader = try FailingByteReader(url: Fixture.url(Fixture.mp3), failAt: 0, error: lost)
        XCTAssertThrowsError(try FFmpegStreamDecoder(reader: reader).open()) { error in
            XCTAssertEqual((error as? StreamDecoderError)?.category, .network, "\(error)")
        }
    }

    func testAFileThatCannotBeOpenedIsIO() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try FileByteReader(url: missing)) { error in
            XCTAssertEqual((error as? StreamByteReaderError)?.category, .io, "\(error)")
        }
    }
}
