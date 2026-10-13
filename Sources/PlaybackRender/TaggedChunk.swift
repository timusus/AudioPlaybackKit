import Foundation

/// PCM plus the tags saying which media frames it carries: the only thing that crosses a layer
/// (ADR-0018). The tags are in output order and their frame counts sum to `frameCount`; a
/// zero-frame tag marks an item that produced nothing but must still be reported crossed.
struct TaggedChunk: Sendable {
    var samples: [Float]
    var format: PCMFormat
    var tags: [SegmentTag]
    /// The format the frames were decoded in, which the processors ran at: what the transport reports
    /// as heard. A processor may change the channel count of `format`, never its rate.
    var decodedFormat: PCMFormat

    init(samples: [Float], format: PCMFormat, tags: [SegmentTag]) {
        self.samples = samples
        self.format = format
        self.tags = tags
        decodedFormat = format
    }

    var frameCount: Int64 { Int64(samples.count / format.channelCount) }
}
