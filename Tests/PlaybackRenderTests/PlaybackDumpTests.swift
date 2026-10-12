import CryptoKit
import Foundation
@testable @_spi(Testing) import PlaybackRender
import PlaybackRenderTestSupport
import XCTest

/// The JSON a golden holds: one line per buffer, span and event, so a diff names the line that
/// changed. PCM is hashed per buffer.
private struct PlaybackDump: Codable, Equatable {
    var buffers: [String]
    var played: [String]
    var flushes: [String]
    var events: [String]

    init(_ capture: PlaybackCapture) {
        buffers = capture.buffers.enumerated().map { index, buffer in
            "#\(index) t=\(Self.time(buffer.time)) frames=\(buffer.samples.count / buffer.format.channelCount) "
                + "\(Self.format(buffer.format)) pcm=\(Self.hash(buffer.samples))"
        }
        played = capture.played.map { span in
            guard let format = span.format else {
                return "silence t=\(Self.time(span.start)) for=\(Self.time(span.duration))"
            }
            return "audio t=\(Self.time(span.start)) for=\(Self.time(span.duration)) \(Self.format(format)) "
                + "pcm=\(Self.hash(span.samples))"
        }
        flushes = capture.flushes.map { "t=\(Self.time($0))" }
        events = capture.events
    }

    private static func time(_ seconds: TimeInterval) -> String { String(format: "%.4f", seconds) }

    private static func format(_ format: PCMFormat) -> String { "\(Int(format.sampleRate))Hzx\(format.channelCount)" }

    private static func hash(_ pcm: [Float]) -> String {
        // Float bits, not Int16: the fake sources emit ramps far outside ±1, which would saturate.
        // The values are small integers and gains, so they are exact on every toolchain.
        let bytes = pcm.flatMap { x in withUnsafeBytes(of: x.bitPattern.littleEndian) { Array($0) } }
        return SHA256.hash(data: Data(bytes)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The first line where `self` differs from `golden`, as a failure message.
    func firstDifference(from golden: PlaybackDump) -> String? {
        let sections: [(String, KeyPath<PlaybackDump, [String]>)] = [
            ("buffers", \.buffers), ("played", \.played), ("flushes", \.flushes), ("events", \.events),
        ]
        for (name, path) in sections {
            let actual = self[keyPath: path], expected = golden[keyPath: path]
            guard actual != expected else { continue }
            let index = (0..<max(actual.count, expected.count)).first {
                ($0 < actual.count ? actual[$0] : nil) != ($0 < expected.count ? expected[$0] : nil)
            } ?? 0
            return """
            first difference in \(name)[\(index)] (\(actual.count) lines, golden \(expected.count))
              golden: \(index < expected.count ? expected[index] : "<none>")
              actual: \(index < actual.count ? actual[index] : "<none>")
            """
        }
        return nil
    }
}

/// Dumps in `Dumps/`, read from the test bundle; `GOLDEN_UPDATE=1` rewrites the source copies.
private enum DumpStore {
    static let sourceDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Dumps")

    static var updating: Bool { ProcessInfo.processInfo.environment["GOLDEN_UPDATE"] == "1" }

    static func check(_ dump: PlaybackDump, named name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if updating {
            try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
            try encoder.encode(dump).write(to: sourceDir.appendingPathComponent(name + ".json"))
            return
        }
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Dumps") else {
            return XCTFail("no golden \(name).json: run with GOLDEN_UPDATE=1", file: file, line: line)
        }
        let golden = try JSONDecoder().decode(PlaybackDump.self, from: Data(contentsOf: url))
        if let difference = dump.firstDifference(from: golden) {
            XCTFail("\(name): \(difference)\nGOLDEN_UPDATE=1 to accept", file: file, line: line)
        }
    }
}

/// What reaches the output for a few scenarios, pinned as dumps (media3 `DumpFileAsserts`). Eight
/// frames a second keeps every time exact; a chunk is a quarter second.
final class PlaybackDumpTests: XCTestCase {
    private let mono = PCMFormat(sampleRate: 8, channelCount: 1)
    private let output = FakeAudioOutput()
    private let timer = ManualPumpTimer()
    private let executor = ManualExecutor()
    private let recorder = PlaybackCaptureRecorder<String>()
    private lazy var transport = Transport<String>(output: output, timer: timer, executor: executor) { [recorder] in
        recorder.record($0)
    }

    private lazy var a = FakeItemSource(format: mono, frames: 24, chunkFrames: 2)
    private lazy var b = FakeItemSource(format: mono, frames: 16, chunkFrames: 2, base: 1000)
    private lazy var long = FakeItemSource(format: mono, frames: 80, chunkFrames: 2)

    private func pump() {
        timer.sync()
        executor.runUntilIdle()
        timer.fire()
    }

    private func run(for seconds: TimeInterval) {
        for _ in 0..<Int(seconds * 4) {
            output.advance(by: 0.25)
            pump()
        }
    }

    private func assertDump(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        try DumpStore.check(PlaybackDump(recorder.capture(of: output)), named: name, file: file, line: line)
    }

    func testGaplessTransition() throws {
        transport.setCurrent(item: "a", source: a)
        transport.setNext(item: "b", source: b)
        transport.play()
        pump()
        run(for: 6)
        try assertDump("gapless")
    }

    func testSeekMidItem() throws {
        transport.setCurrent(item: "a", source: a)
        transport.play()
        pump()
        run(for: 1)
        transport.seek(item: "a", toSeconds: 2)
        pump()
        run(for: 3)
        try assertDump("seek")
    }

    func testRateChange() throws {
        transport.setCurrent(item: "a", source: a)
        transport.play()
        pump()
        run(for: 0.5)
        transport.setRate(2)
        timer.sync()
        run(for: 0.5)
        transport.setRate(1)
        timer.sync()
        run(for: 2)
        try assertDump("rate")
    }

    func testProcessorSwap() throws {
        transport.setCurrent(item: "a", source: long)
        transport.play()
        pump()
        run(for: 1)
        transport.setProcessors([GainProcessor()])
        run(for: 9.25)
        try assertDump("processor-swap")
    }

    func testRendererRecovery() throws {
        transport.setCurrent(item: "a", source: a)
        transport.play()
        pump()
        run(for: 1)
        output.injectFailure()
        pump()
        transport.play()
        pump()
        run(for: 3)
        try assertDump("recovery")
    }
}
