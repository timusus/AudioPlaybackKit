import Foundation

/// Which item and media frames a run of output frames carries. A chunk crosses every layer as PCM
/// plus these tags, and a layer that drops or adds frames rewrites them (ADR-0018).
struct SegmentTag: Equatable, Sendable {
    var item: Int
    var mediaStartFrame: Int64
    var frameCount: Int64
}

/// Maps the played output time back to (item, media frame), modelled on media3
/// `DefaultAudioSink.applyMediaPositionParameters` and `applySkipping`.
///
/// Tags are appended in output order, each starting where the last ended, and a tag counts only once
/// the playhead reaches it. Dropped frames and decoder timestamp jumps are a jump in media start
/// between tags, so the position moves when they would have played. media3 credits dropped frames
/// when the processor drops them (`getSkippedOutputFrameCount`), a buffer-depth early.
///
/// Speed is a time-stretch before the output, which always plays at rate 1 (ADR-0030). Each segment
/// records the output frames its media frames became, so a segment's ratio is the speed it was
/// written at, and frames within it map linearly. This replaces media3's speed checkpoints.
///
/// Output time is in seconds rather than frames because each item keeps its native rate across a
/// join. An item id names a queue entry, not a track: a repeated track needs a new id to be reported.
struct MediaPositionMap: Sendable {
    struct Position: Equatable, Sendable {
        var item: Int
        var mediaFrame: Int64
        /// The rate `mediaFrame` counts at: the item's own, which a format change within it can move.
        var sampleRate: Double

        var seconds: TimeInterval { Double(mediaFrame) / sampleRate }
    }

    /// What the playhead reached, as `advance` returns it.
    enum Heard: Equatable, Sendable {
        /// Another item, in the format its first frames were decoded in.
        case item(Int, PCMFormat)
        /// Another decoded format within the item heard.
        case format(item: Int, PCMFormat)
    }

    private struct Segment: Sendable {
        var tag: SegmentTag
        /// Decoded; processors cannot resample, so its rate is also the output's.
        var format: PCMFormat
        var start: TimeInterval
        /// What `tag.frameCount` media frames became after the stretch; zero while it holds them.
        var outputFrames: Int64
        var sampleRate: Double { format.sampleRate }
        var end: TimeInterval { start + Double(outputFrames) / sampleRate }

        func mediaFrames(ofOutput frames: Int64) -> Int64 {
            if frames == 0 { return 0 }
            return frames == outputFrames ? tag.frameCount : (frames * tag.frameCount + outputFrames / 2) / outputFrames
        }
    }

    private(set) var epochStart: TimeInterval
    private(set) var writtenEnd: TimeInterval
    private var segments: [Segment] = []
    private var reportedItem: Int?
    private var reportedFormat: PCMFormat?

    init(epochStart: TimeInterval = 0) {
        self.epochStart = epochStart
        writtenEnd = epochStart
    }

    /// A flush, seek or auto-flush: everything written is gone and writing restarts at `time`. The
    /// reported item and format are kept, so re-anchoring inside an item reports only a format it changes.
    mutating func reset(at time: TimeInterval) {
        segments = []
        epochStart = time
        writtenEnd = time
    }

    /// An underrun re-anchored the clock at `writtenEnd`: the playhead holds at what is heard now (never
    /// past the written end), then follows the clock again, a latency behind it.
    mutating func hold(at playhead: TimeInterval) {
        epochStart = min(playhead, writtenEnd)
    }

    /// `outputFrames` is what the tag's frames became after the stretch, by default as many.
    mutating func append(_ tag: SegmentTag, format: PCMFormat, outputFrames: Int64? = nil) {
        let outputFrames = outputFrames ?? tag.frameCount
        if let last = segments.last, last.tag.item == tag.item, last.format == format,
           last.tag.mediaStartFrame + last.tag.frameCount == tag.mediaStartFrame,
           last.tag.frameCount * outputFrames == tag.frameCount * last.outputFrames {
            segments[segments.count - 1].tag.frameCount += tag.frameCount
            segments[segments.count - 1].outputFrames += outputFrames
        } else {
            segments.append(Segment(tag: tag, format: format, start: writtenEnd, outputFrames: outputFrames))
        }
        writtenEnd = segments[segments.count - 1].end
    }

    /// A partial flush: drops everything written from `time` on, rounded up to a whole frame so nothing
    /// before the cut is replaced, and returns that cut time and the media position to write from
    /// there. Nil when nothing is written past `time`. The dropped segments start after the playhead,
    /// so none was reported and the reported item and format stay valid.
    mutating func truncate(from time: TimeInterval) -> (time: TimeInterval, resume: Position)? {
        guard var index = segments.firstIndex(where: { $0.end > time || $0.start >= time }) else { return nil }
        var kept = Self.keptOutputFrames(of: segments[index], at: time)
        // A cut within rounding of a segment's end keeps it whole and resumes at the next.
        if kept == segments[index].outputFrames, kept > 0 {
            index += 1
            guard index < segments.count else { return nil }
            kept = 0
        }
        let segment = segments[index]
        let keptMedia = segment.mediaFrames(ofOutput: kept)
        let cut = segment.start + Double(kept) / segment.sampleRate
        let resume = Position(
            item: segment.tag.item,
            mediaFrame: segment.tag.mediaStartFrame + keptMedia,
            sampleRate: segment.sampleRate
        )
        segments.removeSubrange(index...)
        if kept > 0 {
            var shortened = segment
            shortened.tag.frameCount = keptMedia
            shortened.outputFrames = kept
            segments.append(shortened)
        }
        writtenEnd = cut
        return (cut, resume)
    }

    private static func keptOutputFrames(of segment: Segment, at time: TimeInterval) -> Int64 {
        let frames = Int64((((time - segment.start) * segment.sampleRate) - 1e-6).rounded(.up))
        return min(max(frames, 0), segment.outputFrames)
    }

    /// The output time being heard, by the `AudioOutput` rule. It never precedes the epoch: just
    /// after a re-anchor the clock reads the anchor while flushed audio is still leaving the hardware.
    func playhead(currentTime: TimeInterval, outputLatency: TimeInterval) -> TimeInterval {
        max(epochStart, currentTime - outputLatency)
    }

    /// Nil until something of this epoch is written. Past the written end it holds there: a starved
    /// output's clock runs on, the position must not.
    func position(at playhead: TimeInterval) -> Position? {
        guard let index = segmentIndex(at: playhead) else { return nil }
        let segment = segments[index]
        let played = Int64(((min(playhead, writtenEnd) - segment.start) * segment.sampleRate).rounded())
        let output = min(max(played, 0), segment.outputFrames)
        return Position(
            item: segment.tag.item,
            mediaFrame: segment.tag.mediaStartFrame + segment.mediaFrames(ofOutput: output),
            sampleRate: segment.sampleRate
        )
    }

    /// Moves to `playhead` and returns the items and formats it entered since the last call, in order,
    /// a zero-frame item included. Positions behind `playhead` are forgotten.
    mutating func advance(to playhead: TimeInterval) -> [Heard] {
        guard let index = segmentIndex(at: playhead) else { return [] }
        var entered: [Heard] = []
        for segment in segments[...index] {
            let item = segment.tag.item
            if item != reportedItem {
                entered.append(.item(item, segment.format))
            } else if segment.format != reportedFormat {
                entered.append(.format(item: item, segment.format))
            }
            reportedItem = item
            reportedFormat = segment.format
        }
        segments.removeFirst(index)
        return entered
    }

    // A segment counts from half a frame before its start, the nearest frame, so clock rounding
    // never reports a join a frame late.
    private func segmentIndex(at playhead: TimeInterval) -> Int? {
        segments.lastIndex { playhead >= $0.start - 0.5 / $0.sampleRate } ?? segments.indices.first
    }
}
