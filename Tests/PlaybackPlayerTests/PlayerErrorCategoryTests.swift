import Foundation
import PlaybackDecode
import PlaybackRender
import XCTest
@_spi(Testing) import PlaybackPlayerTestSupport
@_spi(Testing) @testable import PlaybackPlayer

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

/// Each failure reaches `itemFailed` with the category an app acts on, through a real decoder.
@MainActor
final class PlayerErrorCategoryTests: XCTestCase {
    /// About twelve seconds of CBR MP3; byte 40 000 is about two and a half seconds in.
    private static let mp3 = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PlaybackDecodeConformanceTests/SeekFixtures/cbr_128k_unpadded_info.mp3")

    override func setUp() async throws {
        try XCTSkipUnless(FFmpegStreamDecoder.isAvailable, "this build has no FFmpeg xcframework")
    }

    /// Plays one item until it fails; the category its `itemFailed` carried.
    private func failedCategory(
        file: StaticString = #filePath, line: UInt = #line,
        _ makeSource: @escaping ItemSourceFactory<String>
    ) async -> PlaybackErrorCategory? {
        let rig = PlayerTestRig<String>(makeSource: makeSource)
        rig.player.setItems(["a"])
        rig.player.play()
        rig.run(for: 6)
        XCTAssertEqual(rig.player.state, .idle, file: file, line: line)
        let stateCategory = rig.player.error?.category
        let errors = await rig.finish().compactMap { event -> PlaybackError? in
            guard case let .itemFailed(_, error) = event else { return nil }
            return error
        }
        // A factory that throws fails at `setItems` and again when `play()` retries it.
        XCTAssertFalse(errors.isEmpty, file: file, line: line)
        XCTAssertEqual(Set(errors.map(\.category)).count, 1, "\(errors)", file: file, line: line)
        XCTAssertEqual(stateCategory, errors.last?.category, "player.error says the same", file: file, line: line)
        return errors.last?.category
    }

    private func readerFailing(with error: Error) -> ItemSourceFactory<String> {
        { _ in FFmpegItemSource(reader: try FailingByteReader(url: Self.mp3, failAt: 40_000, error: error)) }
    }

    func testAConnectionLostMidItemIsNetwork() async {
        let category = await failedCategory(readerFailing(with: URLError(.networkConnectionLost)))
        XCTAssertEqual(category, .network)
    }

    func testAnHTTPStatusKeepsItsCode() async {
        let refused = StreamByteReaderError.failed(StreamFailure(.http(status: 503), detail: "status=503"))
        let category = await failedCategory(readerFailing(with: refused))
        XCTAssertEqual(category, .http(status: 503))
    }

    /// FFmpeg ends truncated or garbled bytes at EOF, so a malformed failure comes from the source:
    /// `GrowingFileByteSource` raises it for a range the server says is past the end.
    func testASourceThatReportsMalformedBytesIsMalformed() async {
        let outOfRange = StreamByteReaderError.failed(StreamFailure(.malformed, detail: "out_of_range status=416"))
        let category = await failedCategory(readerFailing(with: outOfRange))
        XCTAssertEqual(category, .malformed)
    }

    func testAnAppReadersOwnErrorIsIO() async {
        let category = await failedCategory(readerFailing(with: CocoaError(.fileReadUnknown)))
        XCTAssertEqual(category, .io)
    }

    func testAMissingFileIsIO() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let category = await failedCategory { _ in FFmpegItemSource(reader: try FileByteReader(url: missing)) }
        XCTAssertEqual(category, .io)
    }

    func testAPageWhereAudioShouldBeIsUnsupported() async throws {
        let page = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(String(repeating: "<html><body>Not found</body></html>\n", count: 400).utf8).write(to: page)
        addTeardownBlock { try? FileManager.default.removeItem(at: page) }
        let category = await failedCategory { _ in FFmpegItemSource(reader: try FileByteReader(url: page)) }
        XCTAssertEqual(category, .unsupported)
    }

    /// The player cancels only sources it has let go of; a source cancelled under it by the app
    /// still fails the item, and says so.
    func testASourceCancelledByTheAppIsCancelled() async {
        let category = await failedCategory(readerFailing(with: StreamByteReaderError.cancelled))
        XCTAssertEqual(category, .cancelled)
    }

    func testAnAppFactorysOwnErrorIsInternal() async {
        let category = await failedCategory { _ in throw CocoaError(.featureUnsupported) }
        XCTAssertEqual(category, .internal)
    }
}
