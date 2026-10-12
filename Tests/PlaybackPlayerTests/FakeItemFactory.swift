import Foundation
import PlaybackRender
import PlaybackRenderTestSupport

struct FakeOpenError: Error, Equatable {
    var item: String
}

/// Hands a fresh `FakeItemSource` per call and records which items were asked for, in order. Each
/// name's samples start at its own base (a 0, b 1000, c 2000, ...), so audio written says whose it is.
@MainActor
final class FakeItemFactory {
    static let format = PCMFormat(sampleRate: 8, channelCount: 1)
    private static let names = ["a", "b", "c", "d", "x", "y"]

    /// Ten seconds at 8 Hz.
    var frames: Int64 = 80
    /// Items whose source reports no duration, as a live stream does.
    var live: Set<String> = []
    /// Items whose source seeks but reports no duration, as a server transcode does.
    var unknownLength: Set<String> = []
    /// Items whose source has a duration but cannot seek.
    var unseekable: Set<String> = []
    /// Items whose source lands a seek on the whole second before the target, as at a keyframe.
    var coarseSeeks: Set<String> = []
    /// Items whose source blocks in `nextChunk()` at the stall's frame, as a network read-wait does.
    var stalls: [String: ReadStall] = [:]
    /// Items the factory throws for.
    var failing: Set<String> = []
    /// Items whose source throws when decode opens it, as a dead URL does.
    var unopenable: Set<String> = []
    /// Items whose source throws once decode passes this frame, as a dropped connection does.
    var failingAtFrame: [String: Int64] = [:]
    private(set) var calls: [String] = []

    func make(_ item: String) throws -> any ItemSource {
        calls.append(item)
        if failing.contains(item) { throw FakeOpenError(item: item) }
        if unopenable.contains(item) { return UnopenableItemSource(item: item) }
        let source = FakeItemSource(format: Self.format, frames: frames, chunkFrames: 2, base: Self.base(of: item))
        if live.contains(item) { source.duration = nil }
        if unknownLength.contains(item) { (source.duration, source.seekable) = (nil, true) }
        if unseekable.contains(item) { source.seekable = false }
        if let frame = failingAtFrame[item] { return FailingItemSource(source, item: item, frame: frame) }
        if coarseSeeks.contains(item) { return CoarseSeekItemSource(source) }
        if let stall = stalls[item] { return StallingItemSource(source, stall: stall) }
        return source
    }

    static func base(of item: String) -> Float {
        Float(names.firstIndex(of: item)! * 1000)
    }
}

private final class FailingItemSource: ItemSource, @unchecked Sendable {
    private let source: FakeItemSource
    private let item: String
    private let frame: Int64
    private let lock = NSLock()
    private var position: Int64 = 0

    init(_ source: FakeItemSource, item: String, frame: Int64) {
        self.source = source
        self.item = item
        self.frame = frame
    }

    func begin(epoch: UInt64) { source.begin(epoch: epoch) }
    func open() throws -> PCMFormat { try source.open() }

    func seek(toFrame frame: Int64) throws -> Int64 {
        let landed = try source.seek(toFrame: frame)
        lock.withLock { position = landed }
        return landed
    }

    func nextChunk() throws -> [Float]? {
        guard lock.withLock({ position < frame }) else { throw FakeOpenError(item: item) }
        let chunk = try source.nextChunk()
        lock.withLock { position += Int64(chunk?.count ?? 0) }
        return chunk
    }

    func interrupt(through epoch: UInt64) { source.interrupt(through: epoch) }
}

private final class CoarseSeekItemSource: ItemSource, @unchecked Sendable {
    private let source: FakeItemSource

    init(_ source: FakeItemSource) {
        self.source = source
    }

    var duration: Int64? { source.duration }
    var isSeekable: Bool { source.isSeekable }
    func begin(epoch: UInt64) { source.begin(epoch: epoch) }
    func open() throws -> PCMFormat { try source.open() }

    func seek(toFrame frame: Int64) throws -> Int64 {
        let rate = Int64(source.format.sampleRate)
        return try source.seek(toFrame: frame / rate * rate)
    }

    func nextChunk() throws -> [Float]? { try source.nextChunk() }
    func interrupt(through epoch: UInt64) { source.interrupt(through: epoch) }
}

/// Holds one read at `frame` until `release` is signalled, signalling `entered` as it blocks.
final class ReadStall: @unchecked Sendable {
    let frame: Int64
    let entered: DispatchSemaphore
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _hasStalled = false

    var hasStalled: Bool { lock.withLock { _hasStalled } }

    init(frame: Int64, entered: DispatchSemaphore) {
        self.frame = frame
        self.entered = entered
    }

    func block() {
        lock.withLock { _hasStalled = true }
        entered.signal()
        release.wait()
    }
}

private final class StallingItemSource: ItemSource, @unchecked Sendable {
    private let source: FakeItemSource
    private let stall: ReadStall
    private var position: Int64 = 0
    private var stalled = false

    init(_ source: FakeItemSource, stall: ReadStall) {
        self.source = source
        self.stall = stall
    }

    var duration: Int64? { source.duration }
    var isSeekable: Bool { source.isSeekable }
    func begin(epoch: UInt64) { source.begin(epoch: epoch) }
    func open() throws -> PCMFormat { try source.open() }

    func seek(toFrame frame: Int64) throws -> Int64 {
        position = try source.seek(toFrame: frame)
        return position
    }

    // Executor-only, as every call but `interrupt`.
    func nextChunk() throws -> [Float]? {
        if !stalled, position >= stall.frame {
            stalled = true
            stall.block()
        }
        let chunk = try source.nextChunk()
        position += Int64(chunk?.count ?? 0)
        return chunk
    }

    func interrupt(through epoch: UInt64) { source.interrupt(through: epoch) }
}

private final class UnopenableItemSource: ItemSource, @unchecked Sendable {
    let item: String

    init(item: String) {
        self.item = item
    }

    func begin(epoch: UInt64) {}
    func open() throws -> PCMFormat { throw FakeOpenError(item: item) }
    func seek(toFrame frame: Int64) throws -> Int64 { frame }
    func nextChunk() throws -> [Float]? { nil }
    func interrupt(through epoch: UInt64) {}
}
