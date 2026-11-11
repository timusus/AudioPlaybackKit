import Foundation
@testable @_spi(Testing) import PlaybackRender
import PlaybackRenderTestSupport
import XCTest

/// A processor placed after the time-stretch keeps what it mixes in at its length and level at any
/// speed, as an app's cue appended after Sonic does on Android (#196).
final class TransportPostStretchBurstTests: XCTestCase {
    private static let format = PCMFormat(sampleRate: 48000, channelCount: 1)
    /// 0.7 s of 1 kHz at half scale, like the Smart Skip chime.
    private static let burst = (0..<33600).map { 0.5 * Float(sin(2 * Double.pi * 1000 * Double($0) / 48000)) }

    /// The burst as rendered offline through the real stretch at `rate`: its length in seconds and its peak.
    private func renderBurst(at rate: Double, placement: AudioProcessorPlacement) -> (seconds: Double, peak: Float) {
        let output = FakeAudioOutput()
        let timer = ManualPumpTimer()
        let executor = ManualExecutor()
        let transport = Transport<String>(output: output, timer: timer, executor: executor) { _ in }
        let burst = BurstProcessor(Self.burst, after: 24000, placement: placement)
        transport.setProcessors([SilenceProcessor(), burst])
        transport.setRate(rate)
        transport.setCurrent(item: "a", source: FakeItemSource(format: Self.format, frames: 144_000, chunkFrames: 4800))
        transport.play()
        for _ in 0..<40 {
            timer.sync()
            executor.runUntilIdle()
            timer.fire()
            output.advance(by: 0.25)
        }
        XCTAssertEqual(output.flushes, [0])
        let samples = output.enqueues.flatMap(\.samples)
        // -40 dB under the burst: the stretch's smear stays below it.
        let loud = samples.indices.filter { abs(samples[$0]) > 0.005 }
        guard let first = loud.first, let last = loud.last else {
            XCTFail("no burst at \(rate)x")
            return (0, 0)
        }
        return (Double(last - first + 1) / 48000, samples.map(abs).max() ?? 0)
    }

    func testAfterTheStretchABurstKeepsItsLengthAndPeakAtAnySpeed() {
        let reference = renderBurst(at: 1, placement: .afterTimeStretch)
        XCTAssertEqual(reference.seconds, 0.7, accuracy: 0.005)
        for rate in [1.5, 2] {
            let rendered = renderBurst(at: rate, placement: .afterTimeStretch)
            XCTAssertEqual(rendered.seconds, reference.seconds, accuracy: 0.005, "length at \(rate)x")
            XCTAssertEqual(20 * log10(Double(rendered.peak / reference.peak)), 0, accuracy: 0.3, "peak at \(rate)x")
        }
    }

    /// What the output played, silence as zeros, with a burst 1 s in that is 0.3 s ahead of the clock
    /// when `change` re-feeds what is written past `resumeDepth`.
    private func heardBurst(across change: (Transport<String>) -> Void) -> [Float] {
        let output = FakeAudioOutput()
        let timer = ManualPumpTimer()
        let executor = ManualExecutor()
        let transport = Transport<String>(output: output, timer: timer, executor: executor) { _ in }
        transport.setProcessors([SilenceProcessor(), BurstProcessor(Self.burst, after: 48000, placement: .afterTimeStretch)])
        transport.setCurrent(item: "a", source: FakeItemSource(format: Self.format, frames: 240_000, chunkFrames: 4800))
        transport.play()
        func pump() {
            timer.sync()
            executor.runUntilIdle()
            timer.fire()
        }
        pump()
        for _ in 0..<7 {
            output.advance(by: 0.1)
            pump()
        }
        change(transport)
        pump()
        for _ in 0..<30 {
            output.advance(by: 0.1)
            pump()
        }
        XCTAssertEqual(output.partialFlushes.count, 1, "re-fed ahead, not restarted")
        XCTAssertEqual(output.flushes, [0])
        return output.played.flatMap { played -> [Float] in
            switch played {
            case let .audio(_, _, samples): samples
            case let .silence(_, duration): Array(repeating: 0, count: Int((duration * 48000).rounded()))
            }
        }
    }

    private func assertWholeBurst(_ heard: [Float], file: StaticString = #filePath, line: UInt = #line) {
        let loud = heard.indices.filter { abs(heard[$0]) > 0.005 }
        guard let first = loud.first, let last = loud.last else { return XCTFail("no burst", file: file, line: line) }
        XCTAssertEqual(Double(last - first + 1) / 48000, 0.7, accuracy: 0.01, "heard length", file: file, line: line)
        // Each burst sample once, in order: nothing cut out at the re-feed and nothing played twice.
        // The burst's first sample is sin 0, under the threshold.
        let start = first - 1
        let played = Array(heard[start..<min(start + Self.burst.count, heard.count)])
        XCTAssertEqual(played.count, Self.burst.count, file: file, line: line)
        let error = zip(played, Self.burst).map { abs($0 - $1) }.max() ?? .infinity
        XCTAssertLessThan(error, 1e-6, "heard burst against the original", file: file, line: line)
    }

    func testASpeedChangeMidBurstResumesItWhereTheReFeedCut() {
        assertWholeBurst(heardBurst { $0.setRate(1.5) })
    }

    func testAProcessorChangeMidBurstResumesItWhereTheReFeedCut() {
        assertWholeBurst(heardBurst { $0.processorsChanged() })
    }

    func testBeforeTheStretchABurstIsSpedUpWithTheProgramme() {
        XCTAssertEqual(renderBurst(at: 1, placement: .beforeTimeStretch).seconds, 0.7, accuracy: 0.005)
        for rate in [1.5, 2] {
            // The stretch smears each edge by under a window, 43 ms at 48 kHz.
            XCTAssertEqual(renderBurst(at: rate, placement: .beforeTimeStretch).seconds, 0.7 / rate, accuracy: 0.035, "length at \(rate)x")
        }
    }
}

/// Every event a post-stretch processor sees, through the transport's public API at eight frames a
/// second; the stretch keeps each sample whole, so 2x keeps every other frame.
final class TransportPostStretchOrderTests: XCTestCase {
    private let mono = PCMFormat(sampleRate: 8, channelCount: 1)
    private let output = FakeAudioOutput()
    private let timer = ManualPumpTimer()
    private let executor = ManualExecutor()
    private let recorder = EventRecorder()
    private let post = OutputRecordingProcessor()
    private lazy var transport = Transport<String>(output: output, timer: timer, executor: executor,
                                                   stretch: FakeStretchUnit.stretch()) { [recorder] in
        recorder.append($0)
    }

    /// Ten seconds, samples 0 to 79.
    private lazy var long = FakeItemSource(format: mono, frames: 80, chunkFrames: 2)
    /// Three seconds.
    private lazy var a = FakeItemSource(format: mono, frames: 24, chunkFrames: 2)

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

    private func start(_ source: FakeItemSource, processors: [any AudioProcessor] = []) {
        transport.setProcessors(processors + [post])
        transport.setCurrent(item: "a", source: source)
        transport.play()
        pump()
    }

    private func flush(_ item: String, _ frame: Int64) -> OutputRecordingProcessor.Event {
        .flush(StreamMetadata(item: item, mediaStartFrame: frame))
    }

    private var enqueued: [Float] { output.enqueues.flatMap(\.samples) }

    func testItSeesEveryOutputSampleAfterThePreStretchStagesAndStartsWithAConfigureAndFlush() {
        start(a, processors: [GainProcessor()])
        run(for: 4)

        XCTAssertEqual(Array(post.events.prefix(2)), [.configure(mono), flush("a", 0)])
        XCTAssertEqual(post.samples, (0..<24).map { Float($0) * 2 }, "after the doubling stage, in order")
        XCTAssertEqual(post.samples, enqueued)
    }

    func testItWorksInOutputFramesAtDoubleSpeed() {
        transport.setRate(2)
        start(a)
        run(for: 4)

        XCTAssertEqual(post.samples, stride(from: 0, to: 24, by: 2).map(Float.init))
        XCTAssertEqual(post.samples, enqueued)
    }

    func testAGaplessJoinFlushesWithTheNextItemAfterTheLastOutputFrameOfTheOneBefore() {
        start(a)
        transport.setNext(item: "b", source: FakeItemSource(format: mono, frames: 16, chunkFrames: 2, base: 1000))
        run(for: 6)

        let join = post.events.firstIndex(of: flush("b", 0))
        XCTAssertNotNil(join)
        XCTAssertEqual(post.frames(in: post.events.prefix(join ?? 0)), 24)
        XCTAssertEqual(post.frames(in: post.events.dropFirst((join ?? 0) + 1)), 16)
        XCTAssertEqual(post.events.filter { $0 == .reset }.count, 0, "a join is no reset")
    }

    func testAFormatChangeJoinConfiguresBeforeTheFlush() {
        let stereo = PCMFormat(sampleRate: 8, channelCount: 2)
        start(a)
        transport.setNext(item: "b", source: FakeItemSource(format: stereo, frames: 16, chunkFrames: 2, base: 1000))
        run(for: 6)

        let join = post.events.firstIndex(of: flush("b", 0)) ?? 0
        XCTAssertEqual(post.events[join - 1], .configure(stereo))
        XCTAssertEqual(post.frames(in: post.events.dropFirst(join + 1)), 16)
    }

    func testASeekResetsAndFlushesAtTheLandedFrameBeforeAnyFrameAfterIt() {
        start(long)
        run(for: 1)
        let before = post.events.count

        transport.seek(item: "a", toSeconds: 5)
        pump()
        run(for: 1)

        let after = Array(post.events.dropFirst(before))
        XCTAssertEqual(Array(after.prefix(3)), [.reset, .configure(mono), flush("a", 40)])
        XCTAssertEqual(post.samples.suffix(post.frames(in: after)).first, 40)
    }

    func testASpeedChangeFlushesAtTheReFedFrameBeforeTheFirstStretchedFrame() {
        start(long)
        run(for: 1)
        let before = post.events.count

        transport.setRate(2)
        pump()
        output.completePartialFlushes()
        pump()
        run(for: 1)

        let after = Array(post.events.dropFirst(before))
        guard case let .flush(metadata) = after.dropFirst(2).first else { return XCTFail("no flush: \(after)") }
        XCTAssertEqual(Array(after.prefix(2)), [.reset, .configure(mono)])
        XCTAssertEqual(metadata.item as? String, "a")
        let resumed = post.samples.suffix(post.frames(in: after))
        XCTAssertEqual(resumed.first, Float(metadata.mediaStartFrame))
        XCTAssertEqual(Array(resumed.prefix(3)), [0, 2, 4].map { Float(metadata.mediaStartFrame + $0) }, "at 2x")
    }

    func testASpeedChangeStepsAStageThatRewindsBackToTheCutWithoutAResetOrFlush() {
        post.rewinds = true
        start(long)
        run(for: 1)
        let before = post.events.count, processed = post.frames(in: post.events)

        transport.setRate(2)
        pump()
        run(for: 1)

        let after = Array(post.events.dropFirst(before))
        guard case let .rewind(frames) = after.first else { return XCTFail("no rewind: \(after)") }
        // The re-feed keeps what is written up to `resumeDepth`, 0.5 s, past the 1 s clock: frame 12.
        XCTAssertEqual(processed - frames, 12)
        XCTAssertFalse(after.contains { if case .flush = $0 { true } else { $0 == .reset } })
        XCTAssertEqual(Array(post.samples.suffix(post.frames(in: after)).prefix(3)), [12, 14, 16], "at 2x")
    }

    func testAReFeedWhoseDropCrossesIntoTheNextItemResetsEvenAStageThatRewinds() {
        post.rewinds = true
        start(a)
        transport.setNext(item: "b", source: FakeItemSource(format: mono, frames: 16, chunkFrames: 2, base: 1000))
        run(for: 2)
        let before = post.events.count
        XCTAssertNotNil(post.events.firstIndex(of: flush("b", 0)), "written into b")

        transport.setRate(2)
        pump()
        run(for: 1)

        let after = Array(post.events.dropFirst(before))
        XCTAssertEqual(Array(after.prefix(3)), [.reset, .configure(mono), flush("a", 20)])
    }

    func testAChainChangeResetsTheStagesItReplacesAndConfiguresTheNewOnesFresh() {
        start(long)
        run(for: 1)
        let replacement = OutputRecordingProcessor()

        transport.setProcessors([replacement])
        pump()
        run(for: 1)

        XCTAssertEqual(post.events.last, .reset, "swapped out")
        XCTAssertEqual(Array(replacement.events.prefix(2)), [.configure(mono), flush("a", 12)])
    }

    func testAProcessorRunsOnceWhereItsPlacementFirstSaidEvenIfItLaterSaysOtherwise() {
        start(a, processors: [FlippingDoubler()])
        run(for: 4)

        XCTAssertEqual(enqueued, (0..<24).map { Float($0) * 2 })
    }

    func testTheEndOfTheStreamIsProcessedBeforeEnded() {
        transport.setRate(1.5)
        start(a)
        run(for: 4)

        XCTAssertTrue(recorder.events.contains { if case .status(.ended) = $0 { true } else { false } })
        XCTAssertEqual(post.samples, enqueued, "the stretch's tail too")
    }

    func testAStallReplaysTheWrittenAudioWithoutProcessingItAgain() {
        start(long)
        run(for: 1)

        output.injectStall()
        pump()
        run(for: 1)

        XCTAssertEqual(output.flushes.count, 2, "the stall restarted the output")
        XCTAssertGreaterThan(enqueued.count, post.samples.count, "the replay was enqueued again")
        XCTAssertEqual(post.samples, (0..<post.samples.count).map(Float.init), "each frame processed once, in order")
        XCTAssertEqual(post.events.filter { $0 == .reset }.count, 0, "a stall is no reset")
    }

    func testStopResetsIt() {
        start(a)
        run(for: 1)

        transport.stop()
        pump()

        XCTAssertEqual(post.events.last, .reset)
    }
}

/// Mixes `burst` into the stream from `after` frames past its first flush.
private final class BurstProcessor: AudioProcessor, @unchecked Sendable {
    let placement: AudioProcessorPlacement
    private let burst: [Float]
    private var frame: Int
    private var channels = 1

    init(_ burst: [Float], after frames: Int, placement: AudioProcessorPlacement) {
        self.burst = burst
        frame = -frames
        self.placement = placement
    }

    func configure(_ input: PCMFormat) throws -> PCMFormat {
        channels = input.channelCount
        return input
    }

    var isActive: Bool { true }

    func process(_ samples: UnsafeMutableBufferPointer<Float>) {
        for index in 0..<samples.count / channels {
            if frame >= 0, frame < burst.count {
                for channel in 0..<channels { samples[index * channels + channel] += burst[frame] }
            }
            frame += 1
        }
    }

    func flush(_ metadata: StreamMetadata) {}
    func reset() {}

    func rewind(outputFrames frames: Int) -> Bool {
        frame -= frames
        return true
    }
}

/// Doubles each sample, and answers each read of its placement with the other one.
private final class FlippingDoubler: AudioProcessor, @unchecked Sendable {
    private var reads = 0

    var placement: AudioProcessorPlacement {
        reads += 1
        return reads.isMultiple(of: 2) ? .beforeTimeStretch : .afterTimeStretch
    }

    func configure(_ input: PCMFormat) throws -> PCMFormat { input }
    var isActive: Bool { true }

    func process(_ samples: UnsafeMutableBufferPointer<Float>) {
        for index in samples.indices { samples[index] *= 2 }
    }

    func flush(_ metadata: StreamMetadata) {}
    func reset() {}
}

/// Zeroes the programme, so only the burst is left to measure.
private final class SilenceProcessor: AudioProcessor, @unchecked Sendable {
    func configure(_ input: PCMFormat) throws -> PCMFormat { input }
    var isActive: Bool { true }
    func process(_ samples: UnsafeMutableBufferPointer<Float>) { samples.update(repeating: 0) }
    func flush(_ metadata: StreamMetadata) {}
    func reset() {}
}

private final class OutputRecordingProcessor: AudioProcessor, @unchecked Sendable {
    enum Event: Equatable {
        case configure(PCMFormat)
        case flush(StreamMetadata)
        case input([Float], frames: Int)
        case reset
        case rewind(Int)
    }

    private(set) var events: [Event] = []
    private var staged = 1
    private var channels = 1
    /// Whether it steps back at a re-feed, or takes the default reset.
    var rewinds = false

    var placement: AudioProcessorPlacement { .afterTimeStretch }

    func configure(_ input: PCMFormat) throws -> PCMFormat {
        events.append(.configure(input))
        staged = input.channelCount
        return input
    }

    var isActive: Bool { true }

    func process(_ samples: UnsafeMutableBufferPointer<Float>) {
        events.append(.input(Array(samples), frames: samples.count / channels))
    }

    func flush(_ metadata: StreamMetadata) {
        channels = staged
        events.append(.flush(metadata))
    }

    func reset() {
        events.append(.reset)
    }

    func rewind(outputFrames frames: Int) -> Bool {
        guard rewinds else { return false }
        events.append(.rewind(frames))
        return true
    }

    var samples: [Float] {
        events.flatMap { event -> [Float] in
            guard case let .input(samples, _) = event else { return [] }
            return samples
        }
    }

    func frames(in events: some Sequence<Event>) -> Int {
        events.reduce(0) { total, event in
            guard case let .input(_, frames) = event else { return total }
            return total + frames
        }
    }
}
