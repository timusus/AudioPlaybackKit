import XCTest
@testable import PlaybackStreaming
import PlaybackDecode
import PlaybackStreamingTestSupport

/// A seeded chaos origin under the whole read path: whatever the seed does to the wire, the
/// decoder produces the clean decode's PCM or stops with a failure, and never hangs. A failing
/// seed is named in the message; `STREAM_CHAOS_SEEDS=<n>` runs seeds 1...n.
final class StreamingChaosTests: XCTestCase {

    private static let fixedSeeds: [UInt64] = [1, 2, 3, 4, 5, 6]
    private static let deadlineSeconds: TimeInterval = 20

    private var directory: URL!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("streaming-chaos-\(UUID().uuidString)")
        session = GrowingFileByteSource.makeSession(configuration: .ephemeral)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private enum Outcome {
        case decoded([Float])
        case failed(partial: [Float])
    }

    private func decode(_ decoder: FFmpegStreamDecoder) -> Outcome {
        do { _ = try decoder.open() } catch { return .failed(partial: []) }
        var samples: [Float] = []
        while let chunk = decoder.nextChunk() { samples += chunk }
        return decoder.endReason == .eof ? .decoded(samples) : .failed(partial: samples)
    }

    private func runChaos(seed: UInt64, fixture: URL, expected: [Float]) throws {
        let server = try LoopbackMediaServer(body: Data(contentsOf: fixture), mimeType: "audio/mpeg")
        defer { server.stop() }
        server.chaosSeed = seed

        let clock = ManualGrowingFileClock()
        let source = GrowingFileByteSource(
            url: server.url, authHeaders: [:], store: GrowingFileStore(directory: directory.appendingPathComponent("\(seed)")),
            session: session, clock: clock, pathMonitor: GrowingFilePathMonitor()
        )
        defer { source.cancel() }
        let decoder = FFmpegStreamDecoder(reader: source)
        source.isProbing = true

        let finished = DispatchSemaphore(value: 0)
        var outcome: Outcome?
        Thread.detachNewThread {
            outcome = self.decode(decoder)
            finished.signal()
        }
        // The clock steps while the source owes the network nothing, so backoffs and idle timeouts
        // of a hung body pass without a wall-clock wait.
        // A body the origin has gone silent on keeps the source awaiting the network, so the clock
        // also steps once no byte has been served for a beat.
        let deadline = Date().addingTimeInterval(Self.deadlineSeconds)
        var lastServed = server.servedBytes, quietTicks = 0
        while finished.wait(timeout: .now() + 0.005) == .timedOut, Date() < deadline {
            quietTicks = server.servedBytes == lastServed ? quietTicks + 1 : 0
            lastServed = server.servedBytes
            if !source.awaitsNetworkForTest || quietTicks >= 40 { clock.advance(by: 0.5) }
        }
        guard let outcome else {
            decoder.cancel()
            source.cancel()
            _ = finished.wait(timeout: .now() + 5)
            return XCTFail("seed \(seed): no end within \(Self.deadlineSeconds) s")
        }
        switch outcome {
        case .decoded(let samples):
            XCTAssertTrue(samples == expected, "seed \(seed): the PCM differs from the clean decode (\(samples.count) vs \(expected.count) samples)")
        case .failed(let partial):
            XCTAssertTrue(
                partial.count <= expected.count && partial == Array(expected.prefix(partial.count)),
                "seed \(seed): a failed decode produced PCM that is not a prefix of the clean decode"
            )
        }
    }

    func testSeededChaosDecodesCleanOrFails() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "tone-45s", withExtension: "mp3", subdirectory: "Fixtures"))
        let clean = FFmpegStreamDecoder(reader: try FileByteReader(url: fixture))
        _ = try clean.open()
        var expected: [Float] = []
        while let chunk = clean.nextChunk() { expected += chunk }
        XCTAssertFalse(expected.isEmpty)

        let seeds = ProcessInfo.processInfo.environment["STREAM_CHAOS_SEEDS"].flatMap(UInt64.init).map { Array(1...max($0, 1)) }
            ?? Self.fixedSeeds
        for seed in seeds {
            try runChaos(seed: seed, fixture: fixture, expected: expected)
        }
    }
}
