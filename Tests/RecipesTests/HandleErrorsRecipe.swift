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
    case retryLater, refreshAuth, skip, redownload, ignore, report

    init(_ category: PlaybackErrorCategory) {
        switch category {
        case .network, .http(status: 500...), .http(status: 408), .http(status: 429): self = .retryLater
        case .http(status: 401), .http(status: 403): self = .refreshAuth
        case .unsupported, .malformed, .http: self = .skip
        case .io: self = .redownload
        case .cancelled: self = .ignore
        case .internal: self = .report
        }
    }
}

final class HandleErrorsRecipe: XCTestCase {
    func testTheCategoryChoosesTheResponse() {
        XCTAssertEqual(Recovery(.network), .retryLater)
        XCTAssertEqual(Recovery(.http(status: 503)), .retryLater)
        XCTAssertEqual(Recovery(.http(status: 401)), .refreshAuth)
        XCTAssertEqual(Recovery(.http(status: 404)), .skip)
        XCTAssertEqual(Recovery(.unsupported), .skip)
        XCTAssertEqual(Recovery(.io), .redownload)
    }

    // A file the build cannot read is not worth a retry.
    func testADecoderErrorCarriesItsCategory() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("not audio, just a page of text that is long enough to probe".utf8).write(to: url)

        let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
        XCTAssertThrowsError(try decoder.open()) { error in
            let category = (error as? StreamDecoderError)?.category
            XCTAssertEqual(category, .unsupported)
            XCTAssertEqual(category.map(Recovery.init), .skip)
        }
    }

    // A server answer arrives as `.http`, so a missing episode is skipped and an outage is retried.
    func testAServerStatusIsAnHTTPCategory() throws {
        let server = try LoopbackMediaServer(body: Tone.wav(seconds: 1), mimeType: "audio/wav")
        defer { server.stop() }

        let source = GrowingFileByteSource(url: server.missingURL, authHeaders: [:], store: .temporary())
        defer { source.cancel() }
        let decoder = FFmpegStreamDecoder(reader: source)

        XCTAssertThrowsError(try decoder.open()) { error in
            let category = (error as? StreamDecoderError)?.category
            XCTAssertEqual(category, .http(status: 404))
            XCTAssertEqual(category.map(Recovery.init), .skip)
        }
    }

    // `Player` stops on the failed item and reports it; the app decides whether to skip.
    @MainActor
    func testPlayerStopsOnAFailedItemAndTheAppSkips() throws {
        let broken = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("not audio, just a page of text that is long enough to probe".utf8).write(to: broken)
        let good = try Tone.writeWAV(seconds: 2)
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
    }
}
