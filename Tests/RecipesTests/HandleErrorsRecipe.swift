import PlaybackDecode
import PlaybackPlayer
import PlaybackPlayerTestSupport
import PlaybackRender
import PlaybackStreaming
import PlaybackStreamingTestSupport
import XCTest

/// What the app does about a failed item. The library never retries or skips for you: it stops with
/// the error, and the category says which response is worth trying.
enum Recovery: Equatable {
    case retryLater, refreshURL, skip, redownload, ignore, report

    // A flaky link clears in a few tries; past that the app is retrying a dead end.
    static let maxAttempts = 3

    init(_ category: PlaybackErrorCategory, urlError: URLError? = nil, attempt: Int = 0) {
        let retry: Recovery = attempt < Recovery.maxAttempts ? .retryLater : .skip
        switch category {
        case .network where urlError.map(Recovery.noRetryFixes) ?? false: self = .skip
        case .network, .http(status: 500...), .http(status: 408), .http(status: 429): self = retry
        case .http(status: 401), .http(status: 403), .http(status: 404), .http(status: 410): self = .refreshURL
        case .unsupported, .malformed, .http: self = .skip
        case .io: self = .redownload
        case .cancelled: self = .ignore
        case .internal: self = .report
        }
    }

    // An untrusted certificate, a bad URL, ATS refusing cleartext: the same request fails again.
    static func noRetryFixes(_ error: URLError) -> Bool {
        (-1206 ... -1201).contains(error.code.rawValue) || [-1022, -1000, -1002].contains(error.code.rawValue)
    }
}

/// The transport's error behind a failure, when there is one.
func urlError(of error: Error) -> URLError? {
    switch error {
    case let StreamDecoderError.failed(failure), let StreamByteReaderError.failed(failure): failure.urlError
    default: nil
    }
}

final class HandleErrorsRecipe: XCTestCase {
    func testTheCategoryChoosesTheResponse() {
        XCTAssertEqual(Recovery(.network), .retryLater)
        XCTAssertEqual(Recovery(.http(status: 503)), .retryLater)
        XCTAssertEqual(Recovery(.http(status: 401)), .refreshURL)
        XCTAssertEqual(Recovery(.http(status: 404)), .refreshURL)
        XCTAssertEqual(Recovery(.http(status: 416)), .skip)
        XCTAssertEqual(Recovery(.unsupported), .skip)
        XCTAssertEqual(Recovery(.io), .redownload)
    }

    func testANetworkErrorNoRetryFixesIsToldApartByItsURLError() {
        XCTAssertEqual(Recovery(.network, urlError: URLError(.timedOut)), .retryLater)
        XCTAssertEqual(Recovery(.network, urlError: URLError(.serverCertificateUntrusted)), .skip)
        XCTAssertEqual(Recovery(.network, urlError: URLError(.badURL)), .skip)
        XCTAssertEqual(Recovery(.network, urlError: URLError(.appTransportSecurityRequiresSecureConnection)), .skip)
    }

    func testRetriesAreBounded() {
        XCTAssertEqual(Recovery(.network, attempt: Recovery.maxAttempts - 1), .retryLater)
        XCTAssertEqual(Recovery(.network, attempt: Recovery.maxAttempts), .skip)
        XCTAssertEqual(Recovery(.http(status: 503), attempt: Recovery.maxAttempts), .skip)
    }

    // A file the build cannot read is not worth a retry.
    func testADecoderErrorCarriesItsCategory() throws {
        let url = try writeTemp(Data("not audio, just a page of text that is long enough to probe".utf8), ext: "txt")

        let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
        XCTAssertThrowsError(try decoder.open()) { error in
            let category = (error as? StreamDecoderError)?.category
            XCTAssertEqual(category, .unsupported)
            XCTAssertEqual(category.map { Recovery($0) }, .skip)
        }
    }

    // A server answer arrives as `.http`: a missing episode asks for a fresh URL, an outage is retried.
    func testAServerStatusIsAnHTTPCategory() throws {
        let server = try LoopbackMediaServer(body: Tone.wav(seconds: 1), mimeType: "audio/wav")
        defer { server.stop() }

        let source = GrowingFileByteSource(url: server.missingURL, authHeaders: [:], store: .temporary())
        defer { source.cancel() }
        let decoder = FFmpegStreamDecoder(reader: source)

        XCTAssertThrowsError(try decoder.open()) { error in
            let category = (error as? StreamDecoderError)?.category
            XCTAssertEqual(category, .http(status: 404))
            XCTAssertEqual(category.map { Recovery($0) }, .refreshURL)
        }
    }

    // `Player` stops on the failed item and reports it; the app decides whether to skip.
    @MainActor
    func testPlayerStopsOnAFailedItemAndTheAppSkips() throws {
        let broken = try writeTemp(Data("not audio, just a page of text that is long enough to probe".utf8), ext: "txt")
        let good = try writeWAV(seconds: 2)
        let rig = PlayerTestRig<URL> { FFmpegItemSource(reader: try FileByteReader(url: $0)) }
        let player = rig.player!
        var failures: [(index: Int, error: PlaybackError)] = []
        rig.onEvent = {
            guard case let .itemFailed(index, error) = $0 else { return }
            failures.append((index, error))
            // Decided here, from the category, not from the error's text.
            if Recovery(error.category) == .skip { player.remove(at: index) }
        }

        player.setItems([broken, good])
        player.play()
        rig.run(for: 4)

        XCTAssertEqual(failures.map(\.index), [0])
        XCTAssertEqual(failures.first?.error.kind, .source)
        XCTAssertEqual(failures.first?.error.category, .unsupported)
        XCTAssertEqual(player.items, [good])
        XCTAssertNil(player.error)
        XCTAssertEqual(player.currentIndex, 0)
        // The successor played through, with no further `play()`.
        XCTAssertEqual(player.state, .ended)
        XCTAssertEqual(player.position, 2, accuracy: 0.1)
    }

    // Retrying is `play()` again: the item loads afresh from where it stopped.
    @MainActor
    func testPlayAgainRetriesFromThePosition() throws {
        let url = try writeWAV(seconds: 4)
        var online = false
        let rig = PlayerTestRig<URL> {
            guard online else {
                throw StreamDecoderError.failed(StreamFailure(.network, detail: "offline", urlError: URLError(.notConnectedToInternet)))
            }
            return FFmpegItemSource(reader: try FileByteReader(url: $0))
        }
        let player = rig.player!
        var failure: PlaybackError?
        rig.onEvent = {
            if case let .itemFailed(_, error) = $0 { failure = error }
        }

        player.setItems([url])
        player.seek(to: 2)
        player.play()
        rig.run(for: 1)

        XCTAssertEqual(failure?.category, .network)
        XCTAssertEqual(failure.flatMap { urlError(of: $0.underlying) }?.code, .notConnectedToInternet)
        XCTAssertEqual(Recovery(failure!.category, urlError: urlError(of: failure!.underlying)), .retryLater)
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(player.position, 2, accuracy: 0.01)

        online = true
        player.play()
        rig.run(for: 1)

        XCTAssertNil(player.error)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.position, 3, accuracy: 0.3)
    }
}
