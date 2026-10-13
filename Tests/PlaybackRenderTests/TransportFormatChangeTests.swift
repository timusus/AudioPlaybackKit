import Foundation
@testable @_spi(Testing) import PlaybackRender
import PlaybackRenderTestSupport
import XCTest

/// A three-second item a server re-encodes: it opens at 8 Hz mono, and after `switchFrame`, or from
/// any seek, which re-opens the stream at that time as Shuttle2's `TimeOffsetItemSource` does, it is
/// 16 Hz stereo. Samples count from 0 before the change and from 1000 after it.
private final class ReencodedSource: ItemSource, @unchecked Sendable {
    static let before = PCMFormat(sampleRate: 8, channelCount: 1)
    static let after = PCMFormat(sampleRate: 16, channelCount: 2)

    let switchFrame: Int64?
    private(set) var currentFormat: PCMFormat?
    private var position: Int64 = 0

    init(switchFrame: Int64?) {
        self.switchFrame = switchFrame
    }

    var frameCount: Int64? { Int64(3 * format.sampleRate) }
    private var format: PCMFormat { currentFormat ?? Self.before }

    func begin(epoch: UInt64) {}
    func open() throws -> PCMFormat { Self.before }

    func seek(toFrame frame: Int64) throws -> Int64 {
        let seconds = Double(frame) / format.sampleRate
        currentFormat = Self.after
        position = Int64((seconds * Self.after.sampleRate).rounded())
        return position
    }

    func nextChunk() throws -> [Float]? {
        if currentFormat == nil, position == switchFrame {
            currentFormat = Self.after
            position *= 2
        }
        guard position < frameCount! else { return nil }
        let channels = Int64(format.channelCount)
        let end = min(position + 2, frameCount!)
        defer { position = end }
        let base: Float = currentFormat == nil ? 0 : 1000
        return (position * channels..<end * channels).map { base + Float($0) }
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
        start(ReencodedSource(switchFrame: 8))
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
        start(ReencodedSource(switchFrame: nil))
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
        start(ReencodedSource(switchFrame: 8))
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
}
