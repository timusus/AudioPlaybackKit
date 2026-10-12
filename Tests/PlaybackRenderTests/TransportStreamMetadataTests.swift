import Foundation
@testable @_spi(Testing) import PlaybackRender
import PlaybackRenderTestSupport
import XCTest

/// Each processor flush names the item whose frames follow, as media3 `AudioProcessor.flush(StreamMetadata)`
/// does (ADR-0021), through the transport's public API at eight frames a second.
final class TransportStreamMetadataTests: XCTestCase {
    private let mono = PCMFormat(sampleRate: 8, channelCount: 1)
    private let output = FakeAudioOutput()
    private let timer = ManualPumpTimer()
    private let executor = ManualExecutor()
    private let recorder = EventRecorder()
    private let processor = RecordingProcessor()
    private lazy var transport = Transport<String>(output: output, timer: timer, executor: executor) { [recorder] in
        recorder.append($0)
    }

    /// Three seconds in two-frame chunks.
    private lazy var a = FakeItemSource(format: mono, frames: 24, chunkFrames: 2)
    /// Two seconds in two-frame chunks.
    private lazy var b = FakeItemSource(format: mono, frames: 16, chunkFrames: 2, base: 1000)

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

    private func flush(_ item: String, _ frame: Int64) -> RecordingProcessor.Event {
        .flush(StreamMetadata(item: item, mediaStartFrame: frame))
    }

    private func inputs(_ chunks: Int, frames: Int = 2) -> [RecordingProcessor.Event] {
        Array(repeating: .input(frames: frames), count: chunks)
    }

    private func start(next: FakeItemSource) {
        transport.setProcessors([processor])
        transport.setCurrent(item: "a", source: a)
        transport.setNext(item: "b", source: next)
        transport.play()
        pump()
    }

    func testAGaplessJoinFlushesWithTheNextItemAfterTheLastFrameOfTheOneBefore() {
        start(next: b)
        run(for: 6)

        XCTAssertEqual(processor.events, [flush("a", 0)] + inputs(12) + [flush("b", 0)] + inputs(8))
        XCTAssertEqual(output.flushes, [0])
        XCTAssertTrue(recorder.events.contains { if case .crossed("b", _) = $0 { true } else { false } })
    }

    func testAFormatChangeJoinFlushesWithTheNextItem() {
        start(next: FakeItemSource(format: PCMFormat(sampleRate: 8, channelCount: 2), frames: 16, chunkFrames: 2, base: 1000))
        run(for: 6)

        XCTAssertEqual(processor.events, [flush("a", 0)] + inputs(12) + [flush("b", 0)] + inputs(8))
    }

    func testASeekIntoTheNextItemFlushesWithItAtTheLandedFrame() {
        start(next: b)
        run(for: 0.5)
        let before = processor.events.count

        transport.seek(item: "b", toSeconds: 1)
        pump()
        run(for: 2)

        XCTAssertEqual(Array(processor.events.dropFirst(before)), [flush("b", 8)] + inputs(4))
    }

    func testAGaplessJoinKeepsTheAudioAHoldingProcessorHeldBack() {
        transport.setProcessors([DelayProcessor(frames: 3)])
        transport.setCurrent(item: "a", source: a)
        transport.setNext(item: "b", source: b)
        transport.play()
        pump()
        run(for: 6)

        let heard = output.played.flatMap { span -> [Float] in
            guard case let .audio(_, _, samples) = span else { return [] }
            return samples
        }
        XCTAssertEqual(heard, (0..<24).map(Float.init) + (1000..<1016).map(Float.init))
    }
}
