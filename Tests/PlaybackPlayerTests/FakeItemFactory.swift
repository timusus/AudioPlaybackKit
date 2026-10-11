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
        if let frame = failingAtFrame[item] { return FailingItemSource(source, item: item, frame: frame) }
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
