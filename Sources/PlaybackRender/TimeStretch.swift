import Foundation

/// Applies speed to tagged chunks after the processors, so the output always plays at rate 1
/// (ADR-0030). At rate 1 with nothing held, chunks pass through untouched.
///
/// Sonic holds up to two pitch periods of input, so a tag's frames come out later and in different
/// numbers. Each tag's frames wait here until Sonic has consumed them, then take a share of what
/// came out in proportion to their length, which the map records per segment.
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
    private var sonic: Sonic?
    private var format: PCMFormat?
    /// Tags in Sonic not yet consumed, oldest first.
    private var pending: [(tag: SegmentTag, format: PCMFormat)] = []
    private var pendingFrames: Int64 = 0

    mutating func process(_ chunk: TaggedChunk, rate: Double) -> [Chunk] {
        self.rate = rate
        var chunks: [Chunk] = []
        if chunk.frameCount > 0, sonic != nil, chunk.format != format {
            chunks += finish()
        }
        if sonic == nil, rate == 1 || chunk.frameCount == 0 {
            let spans = chunk.tags.map { Span(tag: $0, format: chunk.decodedFormat, outputFrames: $0.frameCount) }
            return chunks + [Chunk(samples: chunk.samples, format: chunk.format, spans: spans)]
        }
        if sonic == nil {
            sonic = Sonic(sampleRate: chunk.format.sampleRate, channels: chunk.format.channelCount, speed: rate)
            format = chunk.format
        }
        sonic!.speed = rate
        for tag in chunk.tags {
            pending.append((tag, chunk.decodedFormat))
            pendingFrames += tag.frameCount
        }
        let samples = chunk.frameCount > 0 ? sonic!.process(chunk.samples) : []
        let consumed = pendingFrames - Int64(sonic!.bufferedFrames)
        if let stretched = take(consumed: consumed, samples: samples) { chunks.append(stretched) }
        // Sonic copied everything it held, so what follows can bypass it.
        if rate == 1 { sonic = nil }
        return chunks
    }

    /// Flushes what Sonic holds, at the end of upstream or before a format change.
    mutating func finish() -> [Chunk] {
        guard sonic != nil else { return [] }
        let samples = sonic!.finish()
        let chunk = take(consumed: pendingFrames, samples: samples)
        sonic = nil
        return chunk.map { [$0] } ?? []
    }

    /// A flush dropped what follows the written audio; upstream supplies it again.
    mutating func reset() {
        sonic = nil
        pending = []
        pendingFrames = 0
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
