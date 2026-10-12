import Foundation

/// Input frames a processor discarded immediately before output frame `atOutputFrame` (equal to the
/// output's frame count for a drop at its end). This is all the pipeline needs to rewrite tags:
/// output frames otherwise map one to one, in order, onto the input not dropped.
public struct DroppedFrames: Equatable, Sendable {
    public var atOutputFrame: Int
    public var inputFrames: Int64

    public init(atOutputFrame: Int, inputFrames: Int64) {
        self.atOutputFrame = atOutputFrame
        self.inputFrames = inputFrames
    }
}

public struct ProcessorOutput: Sendable {
    public var samples: [Float]
    /// In output order.
    public var dropped: [DroppedFrames]

    public init(samples: [Float] = [], dropped: [DroppedFrames] = []) {
        self.samples = samples
        self.dropped = dropped
    }
}

/// The item a processor is about to receive frames of, given at each `flush`, modelled on media3
/// `AudioProcessor.StreamMetadata` (ADR-0021).
public struct StreamMetadata: Sendable, CustomStringConvertible {
    /// The app's item, as given to `Transport` or `Player`; cast it back to that type.
    public let item: any Hashable & Sendable
    /// The item's media frame, at its own rate, of the first frame after this flush: 0 at a join,
    /// the landed frame after a seek.
    public let mediaStartFrame: Int64

    public init(item: any Hashable & Sendable, mediaStartFrame: Int64) {
        self.item = item
        self.mediaStartFrame = mediaStartFrame
    }

    public var description: String { "StreamMetadata(item: \(item), mediaStartFrame: \(mediaStartFrame))" }
}

extension StreamMetadata: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        AnyHashable(lhs.item) == AnyHashable(rhs.item) && lhs.mediaStartFrame == rhs.mediaStartFrame
    }
}

public enum AudioProcessingError: Error, Equatable {
    /// Tags count frames at the chunk's rate, so a stage cannot resample; the output stage does.
    case sampleRateChanged(from: PCMFormat, to: PCMFormat)
}

/// One Float32 interleaved PCM-in, PCM-out stage (skip-silence, Voice Boost, ReplayGain, EQ),
/// modelled on media3 `AudioProcessor`. `configure` only stages a format; `flush` applies it, so a
/// format change lands at a point the caller chooses, never mid-stream. Input is taken whole; a
/// stage that holds audio back keeps it until a later `getOutput`, or `queueEndOfStream`.
///
/// Output is the input minus the dropped frames, in order, possibly delayed: a stage never adds
/// frames. Between flushes, output plus dropped never exceeds input, and equals it once ended.
///
/// Every flush is followed by frames of one item only, from `metadata.mediaStartFrame` on: the
/// chain is drained and flushed at every item change, gapless joins included, and after a seek.
///
/// The transport calls every method on its own queue, so state the app also changes (a toggle, a
/// gain, EQ bands) needs the processor's own lock; hence `Sendable`. Such a change applies live, as
/// in media3, from the next chunk processed: that is heard after the audio already queued, about
/// two seconds on. A change to `isActive` or the output format needs `Transport.setProcessors`.
public protocol AudioProcessor: AnyObject, Sendable {
    /// Stages `input` and returns the output format; with `isActive` false the stage is left out.
    func configure(_ input: PCMFormat) throws -> PCMFormat
    /// Whether the staged configuration does anything.
    var isActive: Bool { get }
    func queueInput(_ samples: [Float])
    /// Hands over everything produced so far, once.
    func getOutput() -> ProcessorOutput
    func queueEndOfStream()
    /// True once end of stream was queued and every output sample was handed over.
    var isEnded: Bool { get }
    /// Applies the staged configuration and drops buffered audio; the frames that follow are of
    /// `metadata.item`.
    func flush(_ metadata: StreamMetadata)
    /// Flushes and forgets the staged configuration.
    func reset()
}
