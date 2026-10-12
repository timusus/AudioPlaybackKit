import Foundation
@testable @_spi(Testing) import PlaybackRender

/// Stages the format at `configure` and applies it at `flush`, like media3 `BaseAudioProcessor`.
/// Subclasses override `outputFormat(for:)` and `process`.
// Unchecked: each test drives one from a single queue at a time.
class TestProcessor: AudioProcessor, @unchecked Sendable {
    var enabled = true
    /// Samples handed over per `getOutput`, the rest stays held (media3's small-limit processors).
    var maxOutputSamples = Int.max
    private(set) var appliedInput: PCMFormat?
    private(set) var stagedInput: PCMFormat?
    private var held: [Float] = []
    private var ended = false
    private var endQueued = false
    private var pendingDropped: [DroppedFrames] = []

    func outputFormat(for input: PCMFormat) -> PCMFormat { input }
    func process(_ samples: [Float], format: PCMFormat) -> ProcessorOutput { ProcessorOutput(samples: samples) }

    var isActive: Bool { enabled }

    func configure(_ input: PCMFormat) throws -> PCMFormat {
        stagedInput = input
        return outputFormat(for: input)
    }

    func queueInput(_ samples: [Float]) {
        guard let format = appliedInput else { return }
        let output = process(samples, format: format)
        let heldFrames = held.count / outputFormat(for: format).channelCount
        held += output.samples
        pendingDropped += output.dropped.map {
            DroppedFrames(atOutputFrame: $0.atOutputFrame + heldFrames, inputFrames: $0.inputFrames)
        }
    }

    func getOutput() -> ProcessorOutput {
        let count = min(held.count, maxOutputSamples)
        let dropped = pendingDropped
        precondition(count == held.count || dropped.isEmpty, "drops need unlimited output")
        defer {
            held.removeFirst(count)
            pendingDropped = []
            if endQueued, held.isEmpty { ended = true }
        }
        return ProcessorOutput(samples: Array(held.prefix(count)), dropped: dropped)
    }

    func queueEndOfStream() {
        held += endOfStreamOutput()
        endQueued = true
        if held.isEmpty { ended = true }
    }

    func endOfStreamOutput() -> [Float] { [] }
    var isEnded: Bool { ended }

    func flush(_ metadata: StreamMetadata) {
        clear()
    }

    func reset() {
        clear()
        stagedInput = nil
        appliedInput = nil
    }

    private func clear() {
        appliedInput = stagedInput
        held = []
        pendingDropped = []
        ended = false
        endQueued = false
        onFlush()
    }

    func onFlush() {}
}

extension StreamMetadata {
    static let itemZero = StreamMetadata(item: 0, mediaStartFrame: 0)
}

/// Records each flush's metadata and the input frames between flushes, like a ReplayGain reading
/// its item's gain at flush.
final class RecordingProcessor: TestProcessor, @unchecked Sendable {
    enum Event: Equatable {
        case flush(StreamMetadata)
        case input(frames: Int)
    }

    private(set) var events: [Event] = []

    override func flush(_ metadata: StreamMetadata) {
        super.flush(metadata)
        events.append(.flush(metadata))
    }

    override func process(_ samples: [Float], format: PCMFormat) -> ProcessorOutput {
        events.append(.input(frames: samples.count / format.channelCount))
        return ProcessorOutput(samples: samples)
    }
}

/// One to one, like ReplayGain.
final class GainProcessor: TestProcessor, @unchecked Sendable {
    override func process(_ samples: [Float], format: PCMFormat) -> ProcessorOutput {
        ProcessorOutput(samples: samples.map { $0 * 2 })
    }
}

/// A gain the app changes while playing, read on the processing thread as a Voice Boost level would be.
final class LiveGainProcessor: TestProcessor, @unchecked Sendable {
    private let lock = NSLock()
    private var _gain: Float = 1

    var gain: Float {
        get { lock.withLock { _gain } }
        set { lock.withLock { _gain = newValue } }
    }

    override func process(_ samples: [Float], format: PCMFormat) -> ProcessorOutput {
        let gain = gain
        return ProcessorOutput(samples: samples.map { $0 * gain })
    }
}

/// Holds back the last `frames` input frames, like a lookahead limiter, and hands them over at end of stream.
final class DelayProcessor: TestProcessor, @unchecked Sendable {
    let frames: Int
    private var line: [Float] = []

    init(frames: Int) {
        self.frames = frames
    }

    override func onFlush() { line = [] }

    override func process(_ samples: [Float], format: PCMFormat) -> ProcessorOutput {
        line += samples
        let out = max(0, line.count - frames * format.channelCount)
        defer { line.removeFirst(out) }
        return ProcessorOutput(samples: Array(line.prefix(out)))
    }

    override func endOfStreamOutput() -> [Float] {
        defer { line = [] }
        return line
    }
}

struct UnsupportedRate: Error {}

/// Accepts only `sampleRate`, like a stage whose filter is designed for one rate.
final class FixedRateProcessor: TestProcessor, @unchecked Sendable {
    let sampleRate: Double

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    override func configure(_ input: PCMFormat) throws -> PCMFormat {
        guard input.sampleRate == sampleRate else { throw UnsupportedRate() }
        return try super.configure(input)
    }
}

final class RateDoublingProcessor: TestProcessor, @unchecked Sendable {
    override func outputFormat(for input: PCMFormat) -> PCMFormat {
        PCMFormat(sampleRate: input.sampleRate * 2, channelCount: input.channelCount)
    }
}

/// Averages each frame down to one channel; the frame count is unchanged.
final class MonoProcessor: TestProcessor, @unchecked Sendable {
    override func outputFormat(for input: PCMFormat) -> PCMFormat {
        PCMFormat(sampleRate: input.sampleRate, channelCount: 1)
    }

    override func process(_ samples: [Float], format: PCMFormat) -> ProcessorOutput {
        let channels = format.channelCount
        let frames = samples.count / channels
        return ProcessorOutput(samples: (0..<frames).map { frame in
            samples[frame * channels..<(frame + 1) * channels].reduce(0, +) / Float(channels)
        })
    }
}

/// Drops the input frames in `ranges`, counted from the last flush, and reports them like a
/// skip-silence processor would.
final class DropRangesProcessor: TestProcessor, @unchecked Sendable {
    let ranges: [Range<Int>]
    private var consumed = 0

    init(_ ranges: [Range<Int>]) {
        self.ranges = ranges
    }

    override func onFlush() { consumed = 0 }

    override func process(_ samples: [Float], format: PCMFormat) -> ProcessorOutput {
        let channels = format.channelCount
        var output: [Float] = []
        var dropped: [DroppedFrames] = []
        for frame in 0..<samples.count / channels {
            let index = consumed + frame
            if ranges.contains(where: { $0.contains(index) }) {
                let outputFrames = output.count / channels
                if let last = dropped.last, last.atOutputFrame == outputFrames {
                    dropped[dropped.count - 1].inputFrames += 1
                } else {
                    dropped.append(DroppedFrames(atOutputFrame: outputFrames, inputFrames: 1))
                }
            } else {
                output += samples[frame * channels..<(frame + 1) * channels]
            }
        }
        consumed += samples.count / channels
        return ProcessorOutput(samples: output, dropped: dropped)
    }
}
