import Foundation
@testable @_spi(Testing) import PlaybackRender
import PlaybackRenderTestSupport
import XCTest

/// A three-second item a server re-encodes: it opens in `formats[0]` and moves to the next format at
/// each of `switchFrames` (counted in the format then playing), or on the first seek, which re-opens
/// the stream at that time as Shuttle2's `TimeOffsetItemSource` does. By default it opens at 8 Hz mono
/// and changes to 16 Hz stereo. Samples count from 1000 × the format's index.
private final class ReencodedSource: ItemSource, @unchecked Sendable {
    static let before = PCMFormat(sampleRate: 8, channelCount: 1)
    static let after = PCMFormat(sampleRate: 16, channelCount: 2)

    private let formats: [PCMFormat]
    private var switchFrames: [Int64]
    private let chunkFrames: Int64
    private var index = 0
    private var position: Int64 = 0

    init(switchFrames: [Int64], formats: [PCMFormat] = [before, after], chunkFrames: Int64 = 2) {
        self.switchFrames = switchFrames
        self.formats = formats
        self.chunkFrames = chunkFrames
    }

    var currentFormat: PCMFormat? { index == 0 ? nil : format }
    var frameCount: Int64? { Int64(3 * format.sampleRate) }
    private var format: PCMFormat { formats[index] }

    func begin(epoch: UInt64) {}
    func open() throws -> PCMFormat { formats[0] }

    func seek(toFrame frame: Int64) throws -> Int64 {
        let seconds = Double(frame) / format.sampleRate
        index = max(index, 1)
        position = Int64((seconds * format.sampleRate).rounded())
        return position
    }

    /// Changes format between the sequencer's calls, which the protocol does not allow.
    func switchNow() {
        switchFormat()
    }

    func nextChunk() throws -> [Float]? {
        if position == switchFrames.first {
            switchFrames.removeFirst()
            switchFormat()
        }
        guard position < frameCount! else { return nil }
        let channels = Int64(format.channelCount)
        let end = min(position + chunkFrames, frameCount!)
        defer { position = end }
        let base = Float(1000 * index)
        return (position * channels..<end * channels).map { base + Float($0) }
    }

    private func switchFormat() {
        let old = format.sampleRate
        index += 1
        position = Int64((Double(position) * format.sampleRate / old).rounded())
    }

    func interrupt(through epoch: UInt64) {}
    func release() {}
}

/// A source changing format mid-item plays on through one drain and reconfiguration, as media3
/// `DefaultAudioSink.configure` does on `onOutputFormatChanged` within one period.
final class TransportFormatChangeTests: XCTestCase {
    private let output = FakeAudioOutput()
    private let timer = ManualPumpTimer()
    private let executor = ManualExecutor()
    private let recorder = EventRecorder()
    private let processor = RecordingProcessor()
    private lazy var transport = Transport<String>(output: output, timer: timer, executor: executor) { [recorder] in
        recorder.append($0)
    }

    private func pump() {
        timer.sync()
        executor.runUntilIdle()
        timer.fire()
    }

    private func run(for seconds: TimeInterval) {
        for _ in 0..<Int(seconds * 8) {
            output.advance(by: 0.125)
            pump()
        }
    }

    private func start(_ source: ReencodedSource) {
        transport.setProcessors([processor])
        transport.setCurrent(item: "a", source: source)
        transport.play()
        pump()
    }

    private var failures: Int {
        recorder.events.filter { if case .failed = $0 { true } else { false } }.count
    }

    private var positions: [TimeInterval] {
        recorder.events.compactMap { if case let .position(_, seconds, _, _) = $0 { seconds } else { nil } }
    }

    private var ended: Bool {
        recorder.events.contains { if case .status(.ended) = $0 { true } else { false } }
    }

    private func firstSample(after enqueues: Int) -> Float? {
        output.enqueues.dropFirst(enqueues).first?.samples.first
    }

    private func flush(_ frame: Int64) -> RecordingProcessor.Event {
        .flush(StreamMetadata(item: "a", mediaStartFrame: frame))
    }

    func testAMidItemFormatChangeDrainsReconfiguresAndPlaysOnInTheNewFormat() {
        start(ReencodedSource(switchFrames: [8]))
        run(for: 4)

        XCTAssertEqual(failures, 0)
        XCTAssertEqual(processor.configured, [ReencodedSource.before, ReencodedSource.after])
        XCTAssertEqual(
            processor.events,
            [flush(0)] + Array(repeating: .input(frames: 2), count: 4) + [flush(16)] + Array(repeating: .input(frames: 2), count: 16)
        )
        XCTAssertEqual(output.enqueues.map(\.format), Array(repeating: ReencodedSource.before, count: 4) + Array(repeating: ReencodedSource.after, count: 16))
        XCTAssertEqual(output.enqueues[4].samples, [1032, 1033, 1034, 1035])
        XCTAssertEqual(output.enqueues[4].time, 1, "the new format follows the old with no gap")
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertTrue(positions.contains(1))
        XCTAssertEqual(positions.last, 3)
        XCTAssertTrue(ended)
    }

    func testASeekThatReopensInAnotherFormatPlaysOnFromTheTarget() {
        start(ReencodedSource(switchFrames: []))
        run(for: 0.5)
        let enqueues = output.enqueues.count
        let events = processor.events.count
        let sought = positions.count

        transport.seek(item: "a", toSeconds: 2)
        pump()
        run(for: 2)

        XCTAssertEqual(failures, 0)
        XCTAssertEqual(processor.configured.last, ReencodedSource.after)
        XCTAssertEqual(Array(processor.events.dropFirst(events).prefix(2)), [flush(32), .input(frames: 2)])
        XCTAssertEqual(firstSample(after: enqueues), 1064)
        XCTAssertEqual(positions.dropFirst(sought).first, 2)
        XCTAssertEqual(positions.last, 3)
        XCTAssertTrue(ended)
    }

    func testAnAutoFlushHeardBeforeTheChangeRefeedsFromTheSameTime() {
        start(ReencodedSource(switchFrames: [8]))
        run(for: 0.75)
        let enqueues = output.enqueues.count
        let before = positions.last

        output.injectAutoFlush()
        pump()
        run(for: 3)

        XCTAssertEqual(before, 0.75)
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(firstSample(after: enqueues), 1024, "0.75 s re-opened at 16 Hz is frame 12")
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertEqual(positions.last, 3)
    }

    func testAChangeSeenBeforeAChunkWithNoSeekStillKeepsTimeContinuous() {
        let source = ReencodedSource(switchFrames: [])
        start(source)
        source.switchNow()
        run(for: 4)

        XCTAssertEqual(failures, 0)
        XCTAssertEqual(processor.configured, [ReencodedSource.before, ReencodedSource.after])
        XCTAssertEqual(processor.events.filter { if case .flush = $0 { true } else { false } }, [flush(0), flush(16)])
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertEqual(positions.last, 3)
        XCTAssertTrue(ended)
    }
}
