import Foundation
import PlaybackRender
import PlaybackRenderTestSupport

/// What a `FakeItemFactory` item throws, wherever its script makes it fail.
public struct FakeItemError<Item: Hashable & Sendable>: Error, Equatable {
    public var item: Item

    public init(item: Item) {
        self.item = item
    }
}

/// Hands a fresh `FakeItemSource` per call, scripted per item, and records which items were asked
/// for, in order. An item in no set plays `frames` frames of `format`, exactly seekable.
@MainActor
public final class FakeItemFactory<Item: Hashable & Sendable> {
    public let format: PCMFormat
    /// Every item's length unless `lengths` has its own: ten seconds at the default 8 Hz.
    public var frames: Int64 = 80
    public var lengths: [Item: Int64] = [:]
    /// Items decoded at their own format rather than `format`.
    public var formats: [Item: PCMFormat] = [:]
    /// Items whose source reports no duration and cannot seek, as a live stream does.
    public var live: Set<Item> = []
    /// Items whose source seeks but reports no duration, as a server transcode does.
    public var unknownLength: Set<Item> = []
    /// Items whose source has a duration but cannot seek.
    public var unseekable: Set<Item> = []
    /// Items whose source lands a seek on the whole second before the target, as at a keyframe.
    public var coarseSeeks: Set<Item> = []
    /// Items the factory throws for, as an item that cannot be resolved.
    public var failing: Set<Item> = []
    /// Items whose source throws when decode opens it, as a dead URL does.
    public var unopenable: Set<Item> = []
    /// Items whose source throws on any seek that would move it, as a failed range request does.
    public var failingSeeks: Set<Item> = []
    /// Items whose source throws once decode passes this frame, as a dropped connection does.
    public var failingAtFrame: [Item: Int64] = [:]
    /// Items whose audio ends at this frame though the source declares its full length, as a
    /// truncated file does.
    public var endingAtFrame: [Item: Int64] = [:]
    /// Items whose source holds `open()` or a read until the stall is released.
    public var stalls: [Item: SourceStall] = [:]
    public private(set) var calls: [Item] = []
    private let base: (Item) -> Float

    /// `base` is each item's first sample (see `FakeItemSource`), so audio written says whose it is.
    public init(format: PCMFormat = PCMFormat(sampleRate: 8, channelCount: 1), base: @escaping (Item) -> Float = { _ in 0 }) {
        self.format = format
        self.base = base
    }

    public func make(_ item: Item) throws -> any ItemSource {
        calls.append(item)
        if failing.contains(item) { throw FakeItemError(item: item) }
        let source = FakeItemSource(format: formats[item] ?? format, frames: lengths[item] ?? frames, chunkFrames: 2, base: base(item))
        if live.contains(item) { source.duration = nil }
        if unknownLength.contains(item) { (source.duration, source.seekable) = (nil, true) }
        if unseekable.contains(item) { source.seekable = false }
        let script = ScriptedItemSource<Item>.Script(
            unopenable: unopenable.contains(item),
            failsSeeks: failingSeeks.contains(item),
            coarseSeeks: coarseSeeks.contains(item),
            failAt: failingAtFrame[item],
            endAt: endingAtFrame[item],
            stall: stalls[item]
        )
        return ScriptedItemSource(source, item: item, script: script)
    }
}

/// Holds one call of a `FakeItemFactory` source, signalling `entered` as it blocks, until `release()`
/// or an interrupt of the call's epoch, as a network wait returns early when interrupted.
public final class SourceStall: @unchecked Sendable {
    /// Nil holds `open()`; otherwise the first read at or past this frame.
    public let frame: Int64?
    public let entered: DispatchSemaphore
    private let released = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _hasStalled = false
    private var blocking = false
    private var _wasReleased = false

    public var hasStalled: Bool { lock.withLock { _hasStalled } }
    /// Set by the release itself, before the held call wakes, so a test can check it without waiting.
    public var wasReleased: Bool { lock.withLock { _wasReleased } }

    public init(frame: Int64?, entered: DispatchSemaphore = DispatchSemaphore(value: 0)) {
        self.frame = frame
        self.entered = entered
    }

    public func release() {
        lock.withLock { _wasReleased = true }
        released.signal()
    }

    /// Blocks the first time only, so a stall holds one call.
    func block() {
        let first = lock.withLock {
            defer { (_hasStalled, blocking) = (true, !_hasStalled) }
            return !_hasStalled
        }
        guard first else { return }
        entered.signal()
        released.wait()
        lock.withLock { blocking = false }
    }

    /// Releases only a call already held: an interrupt before the stall leaves it to hold.
    func interrupt() {
        guard lock.withLock({ blocking }) else { return }
        release()
    }
}

private final class ScriptedItemSource<Item: Hashable & Sendable>: ItemSource, @unchecked Sendable {
    struct Script {
        var unopenable: Bool
        var failsSeeks: Bool
        var coarseSeeks: Bool
        var failAt: Int64?
        var endAt: Int64?
        var stall: SourceStall?
    }

    private let source: FakeItemSource
    private let item: Item
    private let script: Script
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    // Executor-only, as every call but `interrupt`.
    private var position: Int64 = 0

    init(_ source: FakeItemSource, item: Item, script: Script) {
        self.source = source
        self.item = item
        self.script = script
    }

    var duration: Int64? { source.duration }
    var isSeekable: Bool { source.isSeekable }

    func begin(epoch: UInt64) {
        lock.withLock { self.epoch = epoch }
        source.begin(epoch: epoch)
    }

    func open() throws -> PCMFormat {
        if let stall = script.stall, stall.frame == nil { stall.block() }
        if script.unopenable { throw FakeItemError(item: item) }
        return try source.open()
    }

    func seek(toFrame frame: Int64) throws -> Int64 {
        if script.failsSeeks, frame != position { throw FakeItemError(item: item) }
        let rate = Int64(source.format.sampleRate)
        position = try source.seek(toFrame: script.coarseSeeks ? frame / rate * rate : frame)
        return position
    }

    func nextChunk() throws -> [Float]? {
        if let stall = script.stall, let frame = stall.frame, position >= frame { stall.block() }
        if let failAt = script.failAt, position >= failAt { throw FakeItemError(item: item) }
        if let endAt = script.endAt, position >= endAt { return nil }
        guard var chunk = try source.nextChunk() else { return nil }
        let channels = Int64(source.format.channelCount)
        if let endAt = script.endAt {
            chunk = Array(chunk.prefix(Int((endAt - position) * channels)))
        }
        position += Int64(chunk.count) / channels
        return chunk
    }

    func interrupt(through epoch: UInt64) {
        if lock.withLock({ self.epoch <= epoch }) { script.stall?.interrupt() }
        source.interrupt(through: epoch)
    }
}
