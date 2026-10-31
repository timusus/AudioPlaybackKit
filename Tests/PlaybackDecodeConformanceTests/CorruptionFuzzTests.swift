import Foundation
import XCTest
@testable import PlaybackDecode

/// Seeded corruption of the conformance fixtures, decoded to the end with a couple of seeks. The
/// only claim is that the glue survives: every outcome is a clean end or a `.failed`
/// ``StreamDecoderError`` (`.unseekable` only over a non-seekable reader), within a chunk cap and a
/// wall-clock cap. A crash takes the process down, so the case being run is printed first and a
/// failure carries its seed.
///
/// `FUZZ_ITERATIONS=5000 swift test --filter CorruptionFuzzTests` runs longer; `FUZZ_SEED=n
/// FUZZ_ITERATIONS=1` with the test's `--filter` replays the case printed as `seed n`.
final class CorruptionFuzzTests: XCTestCase {
    private static var iterations: Int? {
        ProcessInfo.processInfo.environment["FUZZ_ITERATIONS"].flatMap(Int.init)
    }

    private static var baseSeed: UInt64 {
        ProcessInfo.processInfo.environment["FUZZ_SEED"].flatMap(UInt64.init) ?? 0x5EED_0132
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(FFmpegStreamDecoder.isAvailable, "no FFmpeg in this build")
    }

    func testMutatedFixturesThroughFileReader() throws {
        let corpus = try Corpus.load()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fuzz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<(Self.iterations ?? 40) {
            let seed = Self.baseSeed &+ UInt64(i)
            var rng = SplitMix64(seed: seed)
            let (fixture, bytes, ops) = corpus.mutant(&rng)
            let url = dir.appendingPathComponent("case.bin")
            try bytes.write(to: url)
            let label = "seed \(seed) \(fixture.name) [\(ops)]"
            print("fuzz: \(label)")
            FuzzDecode.run(reader: try FileByteReader(url: url), seekable: true, maxSeconds: fixture.mutantMaxSeconds, label: label)
        }
    }

    /// Reader behaviour comes from control bytes, as FFmpeg's `tools/target_dem_fuzzer.c` does with its trailer.
    func testMutatedFixturesThroughHostileReader() throws {
        let corpus = try Corpus.load()
        for i in 0..<(Self.iterations ?? 40) {
            let seed = Self.baseSeed &+ UInt64(i)
            var rng = SplitMix64(seed: seed)
            let (fixture, bytes, ops) = corpus.mutant(&rng)
            let reader = HostileReader(data: bytes, control: (0..<8).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            let label = "seed \(seed) \(fixture.name) [\(ops)] reader \(reader.behaviour)"
            print("fuzz: \(label)")
            FuzzDecode.run(reader: reader, seekable: reader.seekable, maxSeconds: fixture.mutantMaxSeconds, label: label)
        }
    }

    /// Unmutated fixtures: the control bytes alone must not crash, and must not lengthen the decode.
    func testCleanFixturesThroughHostileReader() throws {
        let corpus = try Corpus.load()
        for i in 0..<(Self.iterations ?? corpus.fixtures.count) {
            let seed = Self.baseSeed &+ UInt64(i)
            var rng = SplitMix64(seed: seed)
            let fixture = corpus.fixtures[Int(rng.next() % UInt64(corpus.fixtures.count))]
            let reader = HostileReader(data: fixture.data, control: (0..<8).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            let label = "seed \(seed) \(fixture.name) reader \(reader.behaviour)"
            print("fuzz: \(label)")
            FuzzDecode.run(reader: reader, seekable: reader.seekable, maxSeconds: fixture.cleanMaxSeconds, label: label)
        }
    }
}

// MARK: - Corpus

private struct Corpus {
    struct Fixture {
        let name: String
        let data: Data
        let cleanSeconds: Double

        // In seconds, not chunks: a corrupt header can claim another sample rate, which scales the frame
        // count. Duplicated spans lengthen a mutant several-fold; a loop needs far more than that.
        var mutantMaxSeconds: Double { 8 * cleanSeconds + 5 }
        var cleanMaxSeconds: Double { 2 * cleanSeconds + 5 }
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    let fixtures: [Fixture]

    /// Small fixtures only: a decode of each mutant must cost milliseconds.
    static func load(maxBytes: Int = 200_000) throws -> Corpus {
        var fixtures: [Fixture] = []
        for url in GoldenStore.fixtureURLs() {
            let data = try Data(contentsOf: url)
            guard data.count <= maxBytes else { continue }
            let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
            var seconds = 0.0
            if let format = try? decoder.open() {
                while let chunk = decoder.nextChunk() { seconds += Double(chunk.count / max(format.channelCount, 1)) / format.sampleRate }
            }
            fixtures.append(Fixture(name: url.lastPathComponent, data: data, cleanSeconds: seconds))
        }
        guard !fixtures.isEmpty else { throw Failure(description: "fuzz corpus is empty: no fixture of at most \(maxBytes) bytes in GoldenStore.fixtureURLs()") }
        return Corpus(fixtures: fixtures)
    }

    func mutant(_ rng: inout SplitMix64) -> (Fixture, Data, String) {
        let fixture = fixtures[Int(rng.next() % UInt64(fixtures.count))]
        var bytes = fixture.data
        var ops: [String] = []
        for _ in 0..<(1 + Int(rng.next() % 3)) { ops.append(Mutation.apply(to: &bytes, &rng)) }
        return (fixture, bytes, ops.joined(separator: ", "))
    }
}

// MARK: - Decode under test

private enum FuzzDecode {
    static let wallClock: TimeInterval = 30

    static func run(reader: StreamByteReader, seekable: Bool, maxSeconds: Double, label: String, file: StaticString = #filePath, line: UInt = #line) {
        let decoder = FFmpegStreamDecoder(reader: reader)
        let timedOut = Flag()
        let watchdog = DispatchWorkItem { timedOut.set(); decoder.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + wallClock, execute: watchdog)
        defer {
            watchdog.cancel()
            // The watchdog's own cancel() surfaces as .cancelled, so a hang must fail here, not as a typed error.
            XCTAssertFalse(timedOut.value, "exceeded \(wallClock) s: \(label)", file: file, line: line)
        }

        func accept(_ error: Error, _ what: String) {
            guard !timedOut.value else { return }
            switch error as? StreamDecoderError {
            case .failed: break
            case .unseekable where !seekable: break
            default: XCTFail("\(what) ended with \(error): \(label)", file: file, line: line)
            }
        }

        let format: StreamAudioFormat
        do { format = try decoder.open() } catch { accept(error, "open"); return }

        var seconds = 0.0
        while let chunk = decoder.nextChunk() {
            seconds += Double(chunk.count / max(format.channelCount, 1)) / format.sampleRate
            if seconds > maxSeconds { XCTFail("no end after \(seconds) s of audio (cap \(maxSeconds) s): \(label)", file: file, line: line); return }
        }
        if let error = decoder.error { accept(error, "decode") }

        let span = format.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1
        for fraction in [1.0 / 3, 0.9] {
            do { _ = try decoder.seek(toSeconds: span * fraction) } catch { accept(error, "seek"); return }
            for _ in 0..<8 where decoder.nextChunk() == nil { break }
            if let error = decoder.error { accept(error, "decode after seek"); return }
        }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var set_ = false
        func set() { lock.lock(); set_ = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return set_ }
    }
}

// MARK: - Mutations

private enum Mutation {
    static func apply(to data: inout Data, _ rng: inout SplitMix64) -> String {
        guard !data.isEmpty else { return "empty" }
        let count = data.count
        switch rng.next() % 6 {
        case 0:
            let n = 1 + Int(rng.next() % 16)
            for _ in 0..<n { data[Int(rng.next() % UInt64(count))] ^= UInt8(truncatingIfNeeded: rng.next() | 1) }
            return "flip \(n)"
        case 1:
            let keep = Int(rng.next() % UInt64(count))
            data = data.prefix(keep)
            return "truncate \(keep)"
        case 2:
            let (at, len) = span(count, &rng)
            data.insert(contentsOf: Data(data[at..<(at + len)]), at: at)
            return "duplicate \(at)+\(len)"
        case 3:
            let (at, len) = span(count, &rng)
            data.replaceSubrange(at..<(at + len), with: Data(count: len))
            return "zero \(at)+\(len)"
        case 4:
            let n = 1 + Int(rng.next() % 6)
            for _ in 0..<n { data[Int(rng.next() % UInt64(min(count, 64)))] = UInt8(truncatingIfNeeded: rng.next()) }
            return "header \(n)"
        default:
            let (at, len) = span(count, &rng)
            data.removeSubrange(at..<(at + len))
            return "cut \(at)+\(len)"
        }
    }

    private static func span(_ count: Int, _ rng: inout SplitMix64) -> (Int, Int) {
        let at = Int(rng.next() % UInt64(count))
        let len = 1 + Int(rng.next() % UInt64(min(count - at, 4096)))
        return (at, len)
    }
}

// MARK: - Hostile reader

/// Behaviour from eight control bytes: seekable or not, declared size correct / absent / too big /
/// too small, reads of at most 1...N bytes, and an EOF before the real end.
final class HostileReader: StreamByteReader {
    enum Size: Int { case correct, absent, larger, smaller }

    private let data: Data
    let seekable: Bool
    private let size: Size
    private let maxRead: Int
    private let eofAt: Int
    private let lock = NSLock()
    private var offset: Int64 = 0
    private var cancelled = false
    private var rng: SplitMix64

    init(data: Data, control c: [UInt8]) {
        self.data = data
        seekable = c[0] & 3 != 0 // independent bits: every size is tried with and without seeking
        size = Size(rawValue: Int(c[0] >> 2) & 3) ?? .correct
        maxRead = 1 + Int(c[1]) * (c[2] & 1 == 0 ? 1 : 64)
        eofAt = c[3] & 3 == 0 ? Int(UInt64(data.count) * UInt64(c[4]) / 255) : data.count
        rng = SplitMix64(seed: c[5...7].reduce(UInt64(c[1])) { $0 << 8 | UInt64($1) })
    }

    var behaviour: String {
        "seekable=\(seekable) size=\(size) maxRead=\(maxRead) eofAt=\(eofAt)/\(data.count)"
    }

    var totalLength: Int64? {
        switch size {
        case .correct: Int64(data.count)
        case .absent: nil
        case .larger: Int64(data.count) * 2 + 1
        case .smaller: Int64(data.count) / 2
        }
    }

    var position: Int64 { lock.lock(); defer { lock.unlock() }; return offset }

    func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw StreamByteReaderError.cancelled }
        guard offset < eofAt else { return 0 }
        let want = 1 + Int(rng.next() % UInt64(maxRead))
        let n = min(maxLength, want, eofAt - Int(offset))
        data.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress! + Int(offset), byteCount: n) }
        offset += Int64(n)
        return n
    }

    func seek(to target: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw StreamByteReaderError.cancelled }
        guard seekable else { throw StreamByteReaderError.unseekable }
        guard target >= 0 else { throw StreamByteReaderError.failed(StreamFailure(.io, detail: "negative seek")) }
        offset = target
    }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func interrupt() {}
    func clearInterrupt() {}
}

// MARK: - RNG

/// Deterministic across runs and platforms, unlike `SystemRandomNumberGenerator`.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
