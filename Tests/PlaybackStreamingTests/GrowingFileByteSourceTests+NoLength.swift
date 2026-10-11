import XCTest
@testable import PlaybackStreaming
import PlaybackStreamingTestSupport
import PlaybackDecode

extension GrowingFileByteSourceTests {
    // MARK: - A body with no length

    /// A server transcode: `200` whatever the range, chunked, no length anywhere.
    private func startTranscode(body: Data) throws -> LoopbackMediaServer {
        let server = try startServer(body: body)
        server.streamsWithoutLength = true
        server.usesChunkedEncoding = true
        return server
    }

    /// The connection is reset mid body and stays down: the read fails at the frontier rather
    /// than ending the stream there, and no length is learned from the bytes that came.
    func testAResetMidChunkedBodyWithNoLengthFailsTheReadInsteadOfEndingIt() throws {
        let body = makeBody(64 * 1024)
        let server = try startTranscode(body: body)
        server.closesAfterBodyBytes = 20_000
        server.resetsDroppedConnections = true
        server.outageAfterClose = 3600
        let clock = ManualGrowingFileClock()
        let source = makeSource(server.url, clock: clock)
        XCTAssertEqual(try read(source, 10_000), body.prefix(10_000))

        let rest = readAsync(source, Int.max)
        XCTAssertTrue(clock.drive(source, timeout: 60) { rest.finished(within: 0) }, "the window never closed")
        assertTransport(rest.result)
        XCTAssertEqual(source.position, 20_000)
        XCTAssertNil(source.totalLength, "a dropped body gave its length")
        let completions = events.events.filter { if case .download(_, _, true) = $0 { return true } else { return false } }
        XCTAssertEqual(completions, [], "a dropped body was reported complete")
    }

    /// The connection is reset once: the retry asks again, the host that ignores ranges answers
    /// with the body from byte 0, and the read carries on from where it was to the real end.
    func testAResetMidChunkedBodyWithNoLengthIsRetriedFromByteZero() throws {
        let body = makeBody(64 * 1024)
        let server = try startTranscode(body: body)
        server.closesAfterBodyBytes = 20_000
        server.resetsDroppedConnections = true
        let clock = ManualGrowingFileClock()
        let source = makeSource(server.url, clock: clock)

        let all = readAsync(source, Int.max)
        XCTAssertTrue(clock.drive(source) { all.finished(within: 0) }, "the read never came back")
        XCTAssertEqual(try all.result.get(), body)
        XCTAssertEqual(source.totalLength, Int64(body.count))
        let bases = events.transactions.map { event -> Int64? in
            guard case .transaction(let base, _, _, let status) = event, status == 200 else { return nil }
            return base
        }
        XCTAssertEqual(bases, [0, 0], "the drop was not answered by a second transaction from byte 0")
    }

    /// The same body sent whole, its last-chunk and all, is the end of the stream at once.
    func testAChunkedBodyWithNoLengthThatEndsCleanlyIsTheEnd() throws {
        let body = makeBody(64 * 1024)
        let server = try startTranscode(body: body)
        let source = makeSource(server.url)

        XCTAssertEqual(try readToEnd(source), body)
        XCTAssertEqual(source.totalLength, Int64(body.count))
        XCTAssertEqual(server.requestHeads.count, 1, "a whole body was asked for again")
        XCTAssertEqual(events.transactions.count, 1)
    }

    /// A reset mid body with a length is the drop it always was: a resume from the frontier.
    func testAResetMidBodyWithALengthResumesFromTheFrontier() throws {
        let body = makeBody(64 * 1024)
        let server = try startServer(body: body)
        server.closesAfterBodyBytes = 20_000
        server.resetsDroppedConnections = true
        let clock = ManualGrowingFileClock()
        let source = makeSource(server.url, clock: clock)

        let all = readAsync(source, Int.max)
        XCTAssertTrue(clock.drive(source) { all.finished(within: 0) }, "the read never came back")
        XCTAssertEqual(try all.result.get(), body)
        // The resume's 64 KiB overlap before the frontier reaches back to the file's start.
        XCTAssertEqual(server.requestedRanges, [0, 0], "the retry did not resume from the frontier")
        XCTAssertEqual(source.snapshot.transactionGeneration, 1)
    }
}
