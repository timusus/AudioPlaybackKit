import Foundation
import PlaybackRender

/// An item whose sample at frame f, channel c is `base + f * channels + c`, so any slice says where
/// it came from. Seeks are exact.
public final class FakeItemSource: ItemSource, @unchecked Sendable {
    public let format: PCMFormat
    private let frameCount: Int64
    private let chunkFrames: Int64
    private let base: Float
    private var position: Int64 = 0
    private let lock = NSLock()
    private var _interrupts = 0
    /// Runs inside `nextChunk()`, as if the decode were still in flight there.
    public var duringRead: (() -> Void)?

    public var interrupts: Int { lock.withLock { _interrupts } }
    /// The item's length unless a test makes it unknown.
    public var duration: Int64?

    public init(format: PCMFormat, frames: Int64, chunkFrames: Int64 = 100, base: Float = 0) {
        self.format = format
        frameCount = frames
        duration = frames
        self.chunkFrames = chunkFrames
        self.base = base
    }

    public func samples(from: Int64, to: Int64) -> [Float] {
        let channels = Int64(format.channelCount)
        return (from * channels..<to * channels).map { base + Float($0) }
    }

    public func begin(epoch: UInt64) {}

    public func open() throws -> PCMFormat { format }

    public func seek(toFrame frame: Int64) throws -> Int64 {
        position = min(frame, frameCount)
        return position
    }

    public func nextChunk() throws -> [Float]? {
        if let duringRead {
            self.duringRead = nil
            duringRead()
        }
        guard position < frameCount else { return nil }
        let end = min(position + chunkFrames, frameCount)
        defer { position = end }
        return samples(from: position, to: end)
    }

    public func interrupt(through epoch: UInt64) {
        lock.withLock { _interrupts += 1 }
    }
}
