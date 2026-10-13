import Foundation
import PlaybackRender

/// An item whose sample at frame f, channel c is `base + f * channels + c`, so any slice says where
/// it came from. Seeks are exact; an unseekable one throws on any that would move it.
public final class FakeItemSource: ItemSource, @unchecked Sendable {
    public struct Unseekable: Error {}

    public let format: PCMFormat
    private let totalFrames: Int64
    private let chunkFrames: Int64
    private let base: Float
    private var position: Int64 = 0
    private let lock = NSLock()
    private var _interrupts = 0
    /// Runs inside `nextChunk()`, as if the decode were still in flight there.
    public var duringRead: (() -> Void)?

    private var _releases = 0

    public var interrupts: Int { lock.withLock { _interrupts } }
    public var releases: Int { lock.withLock { _releases } }
    /// The item's length unless a test makes it unknown.
    public var frameCount: Int64?
    /// Overrides the protocol's default, seekable while the length is known.
    public var seekable: Bool?
    public var isSeekable: Bool { seekable ?? (frameCount != nil) }

    public init(format: PCMFormat, frames: Int64, chunkFrames: Int64 = 100, base: Float = 0) {
        self.format = format
        totalFrames = frames
        frameCount = frames
        self.chunkFrames = chunkFrames
        self.base = base
    }

    public func samples(from: Int64, to: Int64) -> [Float] {
        let channels = Int64(format.channelCount)
        return (from * channels..<to * channels).map { base + Float($0) }
    }

    public func begin(epoch: UInt64) {}

    public func open() throws -> PCMFormat {
        assertNotReleased()
        return format
    }

    public func seek(toFrame frame: Int64) throws -> Int64 {
        assertNotReleased()
        // As FFmpeg's source throws `unseekable` for a forward-only reader.
        guard isSeekable || frame == position else { throw Unseekable() }
        position = min(frame, totalFrames)
        return position
    }

    public func nextChunk() throws -> [Float]? {
        assertNotReleased()
        if let duringRead {
            self.duringRead = nil
            duringRead()
        }
        guard position < totalFrames else { return nil }
        let end = min(position + chunkFrames, totalFrames)
        defer { position = end }
        return samples(from: position, to: end)
    }

    public func interrupt(through epoch: UInt64) {
        lock.withLock { _interrupts += 1 }
    }

    public func release() {
        lock.withLock { _releases += 1 }
    }

    // The transport calls nothing after `release()`; a fake that kept serving would hide a read of a cancelled download.
    private func assertNotReleased() {
        precondition(releases == 0, "read after release()")
    }
}
