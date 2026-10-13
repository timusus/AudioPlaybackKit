import Foundation
import PlaybackDecode

/// One queue item's decoded PCM as the sequencer drives it. Every call but `interrupt(through:)`
/// comes from the sequencer's executor, one at a time, and may block on the network.
/// `FFmpegItemSource` covers any `StreamByteReader`; an app implements this only for other PCM.
///
/// `open()` may block on resolving the item's URL, as a media3 `DataSource.open` does on its loader
/// thread. `interrupt(through:)` is the one cancellation path: a next item removed, replaced or
/// skipped past while it opens is interrupted, and the open's outcome is dropped.
///
/// The transport owns a source from `setCurrent` or `setNext` until it calls `release()`, as media3's
/// loader owns a `DataSource` until `close()`. That happens when the source leaves the transport:
/// a `setCurrent` (a `Player` load, skip to an unarmed item, or `replaceItems` with another current
/// item) releases every source it replaces; a `setNext` that replaces an unplayed next, or a
/// `clearNext`, releases that next; a crossing into an item releases the ones before it; a next that
/// fails before it is heard, `stop()` and dropping the transport release theirs. A seek releases
/// nothing: it may land in any item still set. A source passed again while still set is not released.
///
/// To follow an item's decode (a listener on its byte source), wrap `FFmpegItemSource` in a source of
/// the app's own that forwards every call, `release()` and `currentFormat` included: the first `open()` is the start of
/// playback, and `seek(toFrame:)` each seek, before the decoder moves. A wrapper is the supported
/// route, so the source protocol stays the one hook.
public protocol ItemSource: AnyObject, Sendable {
    /// Never blocks: the calls that follow belong to the sequencer's `epoch`.
    func begin(epoch: UInt64)
    /// The format of the item's first chunks. May block on network resolution: for a next item
    /// it runs once decode of the item before has ended, about two seconds ahead of the join, so
    /// a slow resolve overlaps that tail. Once interrupted it may return early or throw.
    func open() throws -> PCMFormat
    /// Non-nil once the item's format has changed since `open()`, as a stream re-opened at a time
    /// offset may come back at another rate or channel count; read after every `seek(toFrame:)` and
    /// `nextChunk()`, the only calls that may change it. The chunk returned by the `nextChunk()` that
    /// changes it is already in the new format. From the change on, frames (the one `seek` lands on,
    /// `frameCount`, and the ones `seek` is given) count at the new rate; a change inside `nextChunk()`
    /// keeps time continuous.
    /// The transport drains and reconfigures the processors there, as media3's `DefaultAudioSink` does
    /// on an output format change within one period. Defaults to nil, a format fixed at `open()`.
    var currentFormat: PCMFormat? { get }
    /// The item's length in frames, read once `open()` returns; nil when unknown. Has no default, so
    /// a conformer cannot report an unknown length by forgetting it.
    var frameCount: Int64? { get }
    /// Whether `seek(toFrame:)` can move within the item, read once `open()` returns. A source that
    /// re-opens at a time offset is seekable with no `frameCount`; an item neither seekable nor of known
    /// `frameCount` is live (ADR-0022). Defaults to a known `frameCount`.
    var isSeekable: Bool { get }
    /// Sample-accurate (ADR-0009); returns the media frame it landed on, which reads continue from.
    func seek(toFrame frame: Int64) throws -> Int64
    /// Interleaved PCM, nil at the item's end. A failure throws, so it is never mistaken for an end.
    func nextChunk() throws -> [Float]?
    /// Any thread, never blocks: brings back early every call of `epoch` or before, one in flight or
    /// one about to start, and leaves later epochs' calls alone.
    func interrupt(through epoch: UInt64)
    /// The transport is done with the source: called once, on the executor after any call in flight
    /// has returned, and nothing is called after it. Ends downloads and frees what the source holds.
    /// Required, as media3's `DataSource.close()`: a wrapper forwards it to the source it wraps, and
    /// a source that holds nothing beyond memory implements it empty.
    func release()
}

public extension ItemSource {
    var isSeekable: Bool { frameCount != nil }
    var currentFormat: PCMFormat? { nil }
}

/// `FFmpegStreamDecoder` as an item source. The decoder already trims encoder delay and padding
/// (the gapless goldens), so its frames are the item's frames and the join adds no trim.
///
/// `@unchecked Sendable`: the decoder, epoch and interrupt are guarded by `lock`; `sampleRate`, `frameCount` and
/// `isSeekable` are written by `open()` on the executor and read only after it returns.
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
    public private(set) var frameCount: Int64?
    /// ADR-0017's rule: only a stream with neither a byte length nor a container duration is live.
    public private(set) var isSeekable = false

    /// The source owns `reader` from here on: only the transport's decode executor reads it, and
    /// `release()` cancels it, which ends a `GrowingFileByteSource`'s download.
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
            frameCount = format.duration.map { Int64(($0 * format.sampleRate).rounded()) }
            isSeekable = frameCount != nil || reader.totalLength != nil
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
        case .failure: throw decoder.error ?? StreamDecoderError.invalidState("failed with no error")
        case .running: throw StreamDecoderError.invalidState("no chunk while running")
        }
    }

    public func interrupt(through epoch: UInt64) {
        lock.withLock {
            interruptedThrough = max(interruptedThrough ?? epoch, epoch)
            decoder?.interrupt(through: epoch)
        }
    }

    public func release() {
        lock.withLock { decoder = nil }
        reader.cancel()
    }

    private func opened() throws -> FFmpegStreamDecoder {
        guard let decoder = lock.withLock({ decoder }) else { throw StreamDecoderError.invalidState("not open") }
        return decoder
    }
}
