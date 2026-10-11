import XCTest
@testable import PlaybackStreaming
import PlaybackStreamingTestSupport

/// The overlap at a join through the adapter (ADR-0016), against a host that serves other bytes
/// for each request at the same length, as one that inserts ads per request does.
extension GrowingFileByteSourceTests {

    private func versions(_ count: Int) -> [Data] {
        (0..<count).map { makeBody(256 * 1024, seed: UInt64(40 + $0)) }
    }

    /// No validator and the same total: only the bytes before the join tell. The resume's overlap
    /// differs, so the file is discarded and the read gets one version, never a splice.
    func testAResumeIntoOtherBytesOfTheSameLengthWithNoETagIsNotSpliced() throws {
        let bodies = versions(3)
        let server = try startServer(body: bodies[0])
        server.bodies = bodies
        server.closesAfterBodyBytes = 100_000
        let source = makeSource(server.url)

        XCTAssertEqual(try read(source, 4096), bodies[0].prefix(4096))
        XCTAssertTrue(waitUntil { server.requestedRanges.count == 3 })
        XCTAssertEqual(server.requestedRanges, [0, 34_464, 4096], "the overlap did not restart at the decoder's position")
        XCTAssertEqual(try readToEnd(source), bodies[2].suffix(from: 4096), "another version was spliced onto the file")
        XCTAssertEqual(source.snapshot.transactionGeneration, 2)
        XCTAssertTrue(waitUntil { source.snapshot.isComplete })
        XCTAssertNil(
            GrowingFileStore(directory: directory).completedFile(for: server.url),
            "a file begun at the decoder's position is not the whole resource"
        )
    }

    /// A strong ETag minted per request: the resume's `If-Range` is stale, the host answers the
    /// whole body, and the source restarts instead of splicing.
    func testAStrongETagThatChangesPerRequestRestartsTheResume() throws {
        let bodies = versions(3)
        let server = try startServer(body: bodies[0])
        server.bodies = bodies
        server.etags = ["\"a\"", "\"b\"", "\"c\""]
        server.closesAfterBodyBytes = 100_000
        let source = makeSource(server.url)

        XCTAssertEqual(try read(source, 4096), bodies[0].prefix(4096))
        XCTAssertTrue(waitUntil { server.requestedRanges.count == 3 })
        XCTAssertTrue(server.requestHeads[1].lowercased().contains("if-range: \"a\""), "the resume carried no validator")
        XCTAssertEqual(server.requestedRanges, [0, 34_464, 4096])
        XCTAssertEqual(try readToEnd(source), bodies[2].suffix(from: 4096), "another version was spliced onto the file")
        XCTAssertEqual(source.snapshot.transactionGeneration, 2)
    }

    /// A weak ETag that stays the same over other bytes is no validator: no `If-Range` goes out,
    /// and the overlap catches the change.
    func testAWeakETagOverOtherBytesIsCaughtByTheOverlap() throws {
        let bodies = versions(3)
        let server = try startServer(body: bodies[0])
        server.bodies = bodies
        server.etag = "W/\"a\""
        server.closesAfterBodyBytes = 100_000
        let source = makeSource(server.url)

        XCTAssertEqual(try read(source, 4096), bodies[0].prefix(4096))
        XCTAssertTrue(waitUntil { server.requestedRanges.count == 3 })
        XCTAssertFalse(server.requestHeads[1].lowercased().contains("if-range"), "a weak ETag was sent as If-Range")
        XCTAssertEqual(server.requestedRanges, [0, 34_464, 4096])
        XCTAssertEqual(try readToEnd(source), bodies[2].suffix(from: 4096), "another version was spliced onto the file")
        XCTAssertEqual(source.snapshot.transactionGeneration, 2)
    }

    /// The control, with a strong ETag and with none: the overlap matches, the resume stays in
    /// the same file, and only the overlap is fetched twice.
    func testAResumeFromAStableHostKeepsTheFileAndFetchesOnlyTheOverlapAgain() throws {
        for etag in ["\"v1\"", nil] as [String?] {
            let body = makeBody(256 * 1024)
            let server = try startServer(body: body)
            server.etag = etag
            server.closesAfterBodyBytes = 100_000
            let source = makeSource(server.url)

            XCTAssertEqual(try read(source, 4096), body.prefix(4096))
            XCTAssertEqual(try readToEnd(source), body.suffix(from: 4096), "\(etag ?? "no ETag")")
            XCTAssertEqual(server.requestedRanges, [0, 34_464], "\(etag ?? "no ETag")")
            XCTAssertEqual(server.servedBytes, Int64(body.count) + 65_536, "\(etag ?? "no ETag")")
            XCTAssertEqual(source.snapshot.transactionGeneration, 1, "\(etag ?? "no ETag")")
            XCTAssertTrue(waitUntil { source.snapshot.isComplete })
            let cached = try XCTUnwrap(GrowingFileStore(directory: directory).completedFile(for: server.url))
            XCTAssertEqual(try Data(contentsOf: cached), body, "\(etag ?? "no ETag")")
            source.cancel()
        }
    }
}
