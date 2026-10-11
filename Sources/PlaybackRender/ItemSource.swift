import Foundation
import PlaybackDecode

/// One queue item's decoded PCM as the sequencer drives it. Every call but `interrupt(through:)`
/// comes from the sequencer's executor, one at a time, and may block on the network.
/// `FFmpegItemSource` covers any `StreamByteReader`; an app implements this only for other PCM.
public protocol ItemSource: AnyObject, Sendable {
    /// Never blocks: the calls that follow belong to the sequencer's `epoch`.
    func begin(epoch: UInt64)
    /// The format every chunk of this item has.
    func open() throws -> PCMFormat
    /// Sample-accurate (ADR-0009); returns the media frame it landed on, which reads continue from.
    func seek(toFrame frame: Int64) throws -> Int64
    /// Interleaved PCM, nil at the item's end. A failure throws, so it is never mistaken for an end.
    func nextChunk() throws -> [Float]?
    /// Any thread, never blocks: brings back early every call of `epoch` or before, one in flight or
    /// one about to start, and leaves later epochs' calls alone.
    func interrupt(through epoch: UInt64)
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
