import XCTest
@testable import PlaybackStreaming
import PlaybackDecode
import PlaybackStreamingTestSupport

/// A seeded chaos origin under the whole read path: whatever the seed does to the wire, the
/// decoder recovers and produces the clean decode's PCM, since a plan never faults more often than
/// the source retries. A failing seed is named in the message; `STREAM_CHAOS_SEEDS=<n>` runs seeds 1...n.
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

    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Outcome?
        var outcome: Outcome? { lock.withLock { value } }
        func set(_ outcome: Outcome) {
            lock.withLock { value = outcome }
            ChangeSignal.shared.notify()
        }
    }

    private enum Outcome {
        case decoded([Float])
        case failed(String)
    }

    private func decode(_ decoder: FFmpegStreamDecoder) -> Outcome {
        do { _ = try decoder.open() } catch { return .failed("open threw \(error)") }
        var samples: [Float] = []
        while let chunk = decoder.nextChunk() { samples += chunk }
        return decoder.endReason == .eof ? .decoded(samples) : .failed("ended with \(decoder.endReason) after \(samples.count) samples")
    }

    /// Runs one seed to its end and returns the faults the origin carried out.
    private func runChaos(seed: UInt64, fixture: URL, expected: [Float]) throws -> [LoopbackMediaServer.ChaosFaultKind] {
        let server = try LoopbackMediaServer(body: Data(contentsOf: fixture), mimeType: "audio/mpeg")
        defer { server.stop() }
        server.chaosSeed = seed

        let clock = ManualGrowingFileClock()
        let source = GrowingFileByteSource(
            url: server.url, authHeaders: [:], store: GrowingFileStore(directory: directory.appendingPathComponent("\(seed)")),
            session: session, clock: clock, pathMonitor: GrowingFilePathMonitor()
        )
        source.onChangeForTest = { ChangeSignal.shared.notify() }
        defer { source.cancel() }
        let decoder = FFmpegStreamDecoder(reader: source)
        source.isProbing = true

        let box = OutcomeBox()
        Thread.detachNewThread { box.set(self.decode(decoder)) }

        // The clock moves only once the origin has reached a fault: a hung body leaves the source
        // awaiting the network, so its idle timeout needs the clock; after a drop or reset the source
        // is done with the network and waits out its backoff. It stops once the source has sent its
        // next request, so the new attempt's own timeouts are not run out while loopback answers.
        var faultsSeen = 0, sentAtFault = 0
        while box.outcome == nil {
            let due = waitUntil(Self.deadlineSeconds) {
                guard box.outcome == nil else { return true }
                let faults = server.chaosFaultsReached.count
                if faults != faultsSeen { faultsSeen = faults; sentAtFault = source.requestsSentForTest }
                guard clock.pendingCount > 0, let fault = server.chaosOpenFault,
                      source.requestsSentForTest == sentAtFault else { return false }
                return fault == .hang || !source.awaitsNetworkForTest
            }
            if !due { break }
            if box.outcome == nil { clock.advance(by: 0.5) }
        }
        guard let outcome = box.outcome else {
            decoder.cancel()
            source.cancel()
            XCTFail("seed \(seed): no end within \(Self.deadlineSeconds) s")
            return server.chaosFaultsReached
        }
        // Every plan stays under the source's budget of answered failures in a row, so it must recover.
        switch outcome {
        case .decoded(let samples):
            XCTAssertTrue(samples == expected, "seed \(seed): the PCM differs from the clean decode (\(samples.count) vs \(expected.count) samples)")
        case .failed(let why):
            XCTFail("seed \(seed): the decode did not recover from \(server.chaosFaultsReached): \(why)")
        }
        return server.chaosFaultsReached
    }

    func testSeededChaosRecoversToTheCleanDecode() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "tone-45s", withExtension: "mp3", subdirectory: "Fixtures"))
        let clean = FFmpegStreamDecoder(reader: try FileByteReader(url: fixture))
        _ = try clean.open()
        var expected: [Float] = []
        while let chunk = clean.nextChunk() { expected += chunk }
        XCTAssertFalse(expected.isEmpty)

        let override = ProcessInfo.processInfo.environment["STREAM_CHAOS_SEEDS"].flatMap(UInt64.init)
        let seeds = override.map { Array(1...max($0, 1)) } ?? Self.fixedSeeds
        var kinds = Set<LoopbackMediaServer.ChaosFaultKind>(), cleanRuns = 0
        for seed in seeds {
            let faults = try runChaos(seed: seed, fixture: fixture, expected: expected)
            kinds.formUnion(faults)
            if faults.isEmpty { cleanRuns += 1 }
        }
        // The fixed seeds are only worth running if together they hit every kind of fault.
        guard override == nil else { return }
        XCTAssertEqual(kinds, [.disconnect, .reset, .hang], "the seeds do not cover every fault kind")
        XCTAssertGreaterThan(cleanRuns, 0, "no seed runs without a fault")
    }
}
