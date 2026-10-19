import Foundation

/// Applies speed to tagged chunks after the processors, so the output always plays at rate 1
/// (ADR-0030). At rate 1 with nothing held, chunks pass through untouched.
///
/// The unit pulls exactly rate input frames per output frame, so each render takes all the input it
/// can but the fraction of a frame left over. Its lag is cut from the start and rendered out at the
/// end, so the output lines up with the media and holds all of it. Each tag's frames wait here until
/// their audio has come out, then take a share of it in proportion to their length, which the map
/// records per segment.
struct TimeStretch {
    /// Which media frames became `outputFrames` frames of output.
    struct Span: Equatable {
        var tag: SegmentTag
        /// Decoded, what the map reports as heard.
        var format: PCMFormat
        var outputFrames: Int64
    }

    struct Chunk {
        var samples: [Float]
        var format: PCMFormat
        var spans: [Span]
        var frameCount: Int64 { Int64(samples.count / format.channelCount) }
    }

    /// The rate the last chunk was stretched at.
    private(set) var rate: Double = 1
    private let makeUnit: (PCMFormat) -> any StretchUnit
    private var unit: (any StretchUnit)?
    private var format: PCMFormat?
    /// Output frames still to cut: the unit's lag, rendered from the silence before the first input.
    private var lead = 0
    /// Tags in the unit not yet consumed, oldest first.
    private var pending: [(tag: SegmentTag, format: PCMFormat)] = []
    private var pendingFrames: Int64 = 0

    init(makeUnit: @escaping (PCMFormat) -> any StretchUnit = TimePitchUnit.init) {
        self.makeUnit = makeUnit
    }

    mutating func process(_ chunk: TaggedChunk, rate: Double) -> [Chunk] {
        self.rate = rate
        var chunks: [Chunk] = []
        // The unit holds under a frame of input, so rate 1 ends the stretch at once.
        if chunk.frameCount > 0, unit != nil, chunk.format != format || rate == 1 {
            chunks += finish()
        }
        if unit == nil, rate == 1 || chunk.frameCount == 0 {
            let spans = chunk.tags.map { Span(tag: $0, format: chunk.decodedFormat, outputFrames: $0.frameCount) }
            return chunks + [Chunk(samples: chunk.samples, format: chunk.format, spans: spans)]
        }
        if unit == nil {
            unit = makeUnit(chunk.format)
            format = chunk.format
            lead = unit!.lag(rate)
        }
        unit!.rate = rate
        for tag in chunk.tags {
            pending.append((tag, chunk.decodedFormat))
            pendingFrames += tag.frameCount
        }
        unit!.append(chunk.samples)
        // A frame short of the queue, so rounding never pulls silence mid-stream.
        let samples = render(frames: Int((Double(unit!.queuedFrames) - 1) / rate))
        let held = Int64(unit!.queuedFrames) + Int64(Double(unit!.window) * (rate + 1))
        // Output always stands for some media, or the map could not place it.
        let consumed = min(max(pendingFrames - held, samples.isEmpty ? 0 : 1), pendingFrames)
        if let stretched = take(consumed: consumed, samples: samples) {
            chunks.append(stretched)
        }
        return chunks
    }

    /// Renders what the unit holds, at the end of upstream, before a format change or at rate 1.
    mutating func finish() -> [Chunk] {
        guard let unit else { return [] }
        let samples = render(frames: Int((Double(unit.queuedFrames) / unit.rate).rounded(.up)) + unit.lag(unit.rate))
        let chunk = take(consumed: pendingFrames, samples: samples)
        reset()
        return chunk.map { [$0] } ?? []
    }

    /// A flush dropped what follows the written audio; upstream supplies it again.
    mutating func reset() {
        unit = nil
        lead = 0
        pending = []
        pendingFrames = 0
    }

    private mutating func render(frames: Int) -> [Float] {
        guard let unit, let format else { return [] }
        let samples = unit.render(max(frames, 0))
        let cut = min(lead, samples.count / format.channelCount)
        lead -= cut
        return Array(samples.dropFirst(cut * format.channelCount))
    }

    /// Hands `samples` to the first `consumed` pending frames, split by cumulative share so the
    /// spans sum exactly to the output. Zero-frame tags at the front go with them.
    private mutating func take(consumed: Int64, samples: [Float]) -> Chunk? {
        guard let format else { return nil }
        let produced = Int64(samples.count / format.channelCount)
        // Nothing came out: keep the tags for the output that will.
        guard produced > 0 || consumed == pendingFrames else { return nil }
        var spans: [Span] = []
        var taken: Int64 = 0, given: Int64 = 0
        while let first = pending.first, taken < consumed || first.tag.frameCount == 0 {
            var tag = first.tag
            if taken + tag.frameCount > consumed {
                tag.frameCount = consumed - taken
                pending[0].tag.mediaStartFrame += tag.frameCount
                pending[0].tag.frameCount -= tag.frameCount
            } else {
                pending.removeFirst()
            }
            taken += tag.frameCount
            let share = consumed == 0 ? 0 : produced * taken / consumed - given
            given += share
            spans.append(Span(tag: tag, format: first.format, outputFrames: share))
        }
        pendingFrames -= taken
        guard !spans.isEmpty || produced > 0 else { return nil }
        return Chunk(samples: samples, format: format, spans: spans)
    }
}

private extension StretchUnit {
    /// The lag in output frames at `rate`.
    func lag(_ rate: Double) -> Int {
        window + Int((Double(window) / rate).rounded())
    }
}
