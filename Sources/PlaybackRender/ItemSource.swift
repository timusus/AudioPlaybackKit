import Foundation
import PlaybackDecode

/// One queue item's decoded PCM as the sequencer drives it. Every call but `interrupt(through:)`
/// comes from the sequencer's executor, one at a time, and may block on the network.
/// `FFmpegItemSource` covers any `StreamByteReader`; an app implements this only for other PCM.
///
/// `open()` may block on resolving the item's URL, as a media3 `DataSource.open` does on its loader
/// thread. `interrupt(through:)` is the one cancellation path: a next item removed, replaced or
/// skipped past while it opens is interrupted, and the open's outcome is dropped.
public protocol ItemSource: AnyObject, Sendable {
    /// Never blocks: the calls that follow belong to the sequencer's `epoch`.
    func begin(epoch: UInt64)
    /// The format every chunk of this item has. May block on network resolution: for a next item
    /// it runs once decode of the item before has ended, about two seconds ahead of the join, so
    /// a slow resolve overlaps that tail. Once interrupted it may return early or throw.
    func open() throws -> PCMFormat
    /// The item's length in frames, read once `open()` returns; nil when unknown.
    var duration: Int64? { get }
    /// Whether `seek(toFrame:)` can move within the item, read once `open()` returns. A source that
    /// re-opens at a time offset is seekable with no duration; an item neither seekable nor of known
    /// duration is live (ADR-0022). Defaults to a known duration.
    var isSeekable: Bool { get }
    /// Sample-accurate (ADR-0009); returns the media frame it landed on, which reads continue from.
    func seek(toFrame frame: Int64) throws -> Int64
    /// Interleaved PCM, nil at the item's end. A failure throws, so it is never mistaken for an end.
    func nextChunk() throws -> [Float]?
    /// Any thread, never blocks: brings back early every call of `epoch` or before, one in flight or
    /// one about to start, and leaves later epochs' calls alone.
    func interrupt(through epoch: UInt64)
}

public extension ItemSource {
    var duration: Int64? { nil }
    var isSeekable: Bool { duration != nil }
}

/// `FFmpegStreamDecoder` as an item source. The decoder already trims encoder delay and padding
/// (the gapless goldens), so its frames are the item's frames and the join adds no trim.
public final class FFmpegItemSource: ItemSource, @unchecked Sendable {
    private let reader: StreamByteReader
    private let lock = NSLock()
    // Read by `interrupt(through:)` from any thread; only the executor replaces the decoder. The
    // epoch and interrupt are kept here too, for the fresh decoder each open makes.
    private var decoder: FFmpegStreamDecoder?
    private var epoch: UInt64 = 0
    private var interruptedThrough: UInt64?
    private var sampleRate: Double = 0
    /// As the container states it once probed (an MP3's Xing or Info frame, MP4's sample table).
    public private(set) var duration: Int64?
    /// ADR-0017's rule: only a stream with neither a byte length nor a container duration is live.
    public private(set) var isSeekable = false

    /// The source owns `reader` from here on: only the transport's decode executor reads it.
    public init(reader: StreamByteReader) {
        self.reader = reader
    }

    public func begin(epoch: UInt64) {
        lock.withLock {
            self.epoch = epoch
            decoder?.begin(generation: epoch)
        }
    }

    public func open() throws -> PCMFormat {
        // A decoder whose open was interrupted is unusable, so each open starts a fresh one. The
        // clear forgets an interrupt aimed at a dropped call; the replay keeps one aimed at this epoch.
        let decoder = FFmpegStreamDecoder(reader: reader)
        lock.withLock {
            reader.clearInterrupt()
            decoder.begin(generation: epoch)
            if let interruptedThrough { decoder.interrupt(through: interruptedThrough) }
            self.decoder = decoder
        }
        do {
            let format = try decoder.open()
            sampleRate = format.sampleRate
            duration = format.duration.map { Int64(($0 * format.sampleRate).rounded()) }
            isSeekable = duration != nil || reader.totalLength != nil
            return PCMFormat(sampleRate: format.sampleRate, channelCount: format.channelCount)
        } catch {
            lock.withLock { self.decoder = nil }
            throw error
        }
    }

    public func seek(toFrame frame: Int64) throws -> Int64 {
        let decoder = try opened()
        try decoder.seek(toSeconds: Double(frame) / sampleRate)
        return decoder.mediaFramesRead
    }

    public func nextChunk() throws -> [Float]? {
        let decoder = try opened()
        if let chunk = decoder.nextChunk() { return chunk }
        switch decoder.endReason {
        case .eof: return nil
        case .cancelled: throw StreamDecoderError.cancelled
        case .interrupted: throw StreamDecoderError.interrupted
        // `nextChunk()` does not surface FFmpeg's status, so -1 stands for "unknown".
        case .running, .failure: throw StreamDecoderError.failed(status: -1)
        }
    }

    public func interrupt(through epoch: UInt64) {
        lock.withLock {
            interruptedThrough = max(interruptedThrough ?? epoch, epoch)
            decoder?.interrupt(through: epoch)
        }
    }

    private func opened() throws -> FFmpegStreamDecoder {
        guard let decoder = lock.withLock({ decoder }) else { throw StreamDecoderError.invalidState("not open") }
        return decoder
    }
}
