import XCTest
@testable import PlaybackStreaming
import PlaybackStreamingTestSupport
import PlaybackDecode

/// A host's `GrowingFileListener`, fed the way Podcasts feeds it: the source's events, each with a
/// snapshot taken just after.
private final class RecordingListener: GrowingFileListener, @unchecked Sendable {
    private let lock = NSLock()
    private var _started: [(file: any GrowingFileSnapshotSource, position: () -> Int64)] = []
    private var _seeks: [(ms: Int64, generation: Int)] = []
    private var _received: [(event: GrowingFileEvent, snapshot: GrowingFileSnapshot, fileBytes: Data?)] = []

    var started: [(file: any GrowingFileSnapshotSource, position: () -> Int64)] { lock.withLock { _started } }
    var seeks: [(ms: Int64, generation: Int)] { lock.withLock { _seeks } }
    var received: [(event: GrowingFileEvent, snapshot: GrowingFileSnapshot, fileBytes: Data?)] { lock.withLock { _received } }

    func playbackDidStart(file: any GrowingFileSnapshotSource, decoderPosition: @escaping () -> Int64) {
        lock.withLock { _started.append((file, decoderPosition)) }
    }

    func playerWillSeek(toMs ms: Int64, generation: Int) {
        lock.withLock { _seeks.append((ms, generation)) }
    }

    func growingFile(_ event: GrowingFileEvent, snapshot: GrowingFileSnapshot) {
        // A host reads the file back in the callback; a later promotion renames it.
        let bytes = snapshot.fileURL.flatMap { try? Data(contentsOf: $0) }
        lock.withLock { _received.append((event, snapshot, bytes)) }
        ChangeSignal.shared.notify()
    }
}

extension GrowingFileByteSourceTests {
    // MARK: - Listener and lifecycle

    /// media3 `DataSourceContractTest.transferListenerCallbacks`: a start, then bytes as they move,
    /// then the end; here the transaction, the download events and a snapshot that backs them.
    func testAListenerFedFromTheEventsReadsTheBytesItIsToldAbout() throws {
        let body = makeBody(64 * 1024)
        let server = try startServer(body: body)
        let listener = RecordingListener()
        let box = WeakSourceBox()
        let source = GrowingFileByteSource(
            url: server.url, authHeaders: [:], store: makeStore(), session: Self.testSession,
            clock: SystemGrowingFileClock.shared, pathMonitor: GrowingFilePathMonitor(),
            onEvent: { event in
                if let source = box.source { listener.growingFile(event, snapshot: source.snapshot) }
            }
        )
        box.source = source
        sources.append(source)

        listener.playbackDidStart(file: source, decoderPosition: { source.position })
        XCTAssertEqual(listener.started.count, 1)
        XCTAssertEqual(listener.started[0].position(), 0)
        XCTAssertTrue(listener.started[0].file === source)
        listener.playerWillSeek(toMs: 1500, generation: 4)
        XCTAssertEqual(listener.seeks.first?.ms, 1500)
        XCTAssertEqual(listener.seeks.first?.generation, 4)

        XCTAssertEqual(try readToEnd(source), body)
        XCTAssertEqual(listener.started[0].position(), Int64(body.count), "the decoder's position, live")
        XCTAssertTrue(waitUntil {
            listener.received.contains { if case .download(_, _, true) = $0.event { return true } else { return false } }
        }, "the end is reported")

        let received = listener.received
        // The parked first read is announced before the response; the transaction precedes any download.
        let transactions = received.filter { if case .transaction = $0.event { return true } else { return false } }
        XCTAssertEqual(transactions.count, 1)
        guard case .transaction(let base, let generation, nil, let status)? = transactions.first?.event else {
            return XCTFail("no transaction: \(received.map(\.event))")
        }
        XCTAssertEqual(base, 0)
        XCTAssertEqual(generation, 1)
        XCTAssertEqual(status, 206)
        XCTAssertEqual(transactions.first?.snapshot.transactionGeneration, 1)
        let firstTransaction = received.firstIndex { if case .transaction = $0.event { return true } else { return false } }
        let firstDownload = received.firstIndex { if case .download = $0.event { return true } else { return false } }
        XCTAssertLessThan(try XCTUnwrap(firstTransaction), try XCTUnwrap(firstDownload))

        let downloads = received.compactMap { entry -> (frontier: Int64, snapshot: GrowingFileSnapshot, bytes: Data?)? in
            if case .download(let frontier, _, _) = entry.event { return (frontier, entry.snapshot, entry.fileBytes) } else { return nil }
        }
        XCTAssertEqual(downloads.last?.frontier, Int64(body.count))
        for (frontier, snapshot, bytes) in downloads {
            // The listener reads back from the file, never past what the event said was in it.
            XCTAssertGreaterThanOrEqual(snapshot.frontier, frontier)
            XCTAssertEqual(try XCTUnwrap(bytes).prefix(Int(frontier)), body.prefix(Int(frontier)))
        }
        let last = try XCTUnwrap(downloads.last).snapshot
        XCTAssertTrue(last.isComplete)
        XCTAssertEqual(last.totalLength, Int64(body.count))
    }

    func testASeekAfterCancelThrowsCancelled() throws {
        let body = makeBody(64 * 1024)
        let source = makeSource(try startServer(body: body).url)
        XCTAssertEqual(try read(source, 1000), body.prefix(1000))

        source.cancel()
        XCTAssertThrowsError(try source.seek(to: 10)) { error in
            guard case .cancelled? = error as? StreamByteReaderError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(source.position, 1000, "the refused seek moved nothing")
    }

    func testAnAppHeaderCannotOverrideRangeOrAcceptEncoding() throws {
        let body = makeBody(8 * 1024)
        let server = try startServer(body: body)
        let source = makeSource(
            server.url, authHeaders: ["Accept-Encoding": "gzip", "range": "bytes=5-", "Authorization": "Basic c2VjcmV0"],
            connectionPolicy: GrowingFileConnectionPolicy(headers: ["accept-encoding": "br"])
        )
        XCTAssertEqual(try readToEnd(source), body)
        let sent = try XCTUnwrap(server.requestHeads.first).lowercased()
        XCTAssertTrue(sent.contains("accept-encoding: identity"), sent)
        XCTAssertFalse(sent.contains("gzip") || sent.contains("accept-encoding: br"), sent)
        XCTAssertTrue(sent.contains("range: bytes=0-"), sent)
        XCTAssertTrue(sent.contains("authorization: basic c2vjcmv0"), sent)
    }

    /// media3 `DefaultHttpDataSourceTest.open_redirectCrossProtocol_*`: the loopback server speaks no
    /// TLS, so the scheme change is fed to the delegate; the caller's headers belong to the original
    /// origin (same scheme, host and port) or its `https` upgrade, and the range goes on every hop.
    func testARedirectAcrossSchemesKeepsTheRangeAndOnlyAnUpgradeKeepsTheCallersHeaders() throws {
        let headers = ["Authorization": "Basic c2VjcmV0"]
        for (from, to, keeps) in [("http://host.example/a.mp3", "https://host.example/b.mp3", true),
                                  ("http://host.example:8080/a.mp3", "https://host.example:8080/b.mp3", true),
                                  ("http://host.example:8080/a.mp3", "https://host.example/b.mp3", false),
                                  ("https://host.example/a.mp3", "http://host.example/b.mp3", false),
                                  ("http://host.example/a.mp3", "https://other.example/b.mp3", false),
                                  ("https://host.example/a.mp3", "https://host.example/b.mp3", true)] {
            let source = makeSource(URL(string: from)!, authHeaders: headers)
            var original = URLRequest(url: URL(string: from)!)
            original.setValue("bytes=500-", forHTTPHeaderField: "Range")
            original.setValue("\"v1\"", forHTTPHeaderField: "If-Range")
            let task = Self.testSession.dataTask(with: original)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: URL(string: from)!, statusCode: 302, httpVersion: nil, headerFields: ["Location": to]
            ))
            var carried = URLRequest(url: URL(string: to)!)
            carried.setValue("Basic c2VjcmV0", forHTTPHeaderField: "Authorization")

            var next: URLRequest?
            source.urlSession(Self.testSession, task: task, willPerformHTTPRedirection: response, newRequest: carried) {
                next = $0
            }
            let hop = try XCTUnwrap(next, "\(from) -> \(to)")
            XCTAssertEqual(hop.url?.absoluteString, to)
            XCTAssertEqual(hop.value(forHTTPHeaderField: "Range"), "bytes=500-", "\(from) -> \(to)")
            XCTAssertEqual(hop.value(forHTTPHeaderField: "If-Range"), "\"v1\"", "\(from) -> \(to)")
            XCTAssertEqual(hop.value(forHTTPHeaderField: "Authorization"), keeps ? "Basic c2VjcmV0" : nil, "\(from) -> \(to)")
            task.cancel()
        }
    }

    func testACrossOriginRedirectKeepsThePackagesRangeWhenTheAppSendsItsOwn() throws {
        let from = "http://host.example/a.mp3", to = "https://other.example/b.mp3"
        let source = makeSource(
            URL(string: from)!, authHeaders: ["Range": "bytes=0-", "Authorization": "Basic c2VjcmV0"]
        )
        var original = URLRequest(url: URL(string: from)!)
        original.setValue("bytes=500-", forHTTPHeaderField: "Range")
        let task = Self.testSession.dataTask(with: original)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: from)!, statusCode: 302, httpVersion: nil, headerFields: ["Location": to]
        ))

        var next: URLRequest?
        source.urlSession(
            Self.testSession, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: to)!)
        ) {
            next = $0
        }
        let hop = try XCTUnwrap(next)
        XCTAssertEqual(hop.value(forHTTPHeaderField: "Range"), "bytes=500-")
        XCTAssertNil(hop.value(forHTTPHeaderField: "Authorization"))
        task.cancel()
    }
}

private final class WeakSourceBox: @unchecked Sendable {
    weak var source: GrowingFileByteSource?
}
