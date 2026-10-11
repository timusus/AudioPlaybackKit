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
    private(set) var calls: [String] = []

    func make(_ item: String) throws -> any ItemSource {
        calls.append(item)
        if failing.contains(item) { throw FakeOpenError(item: item) }
        let source = FakeItemSource(format: Self.format, frames: frames, chunkFrames: 2, base: Self.base(of: item))
        if live.contains(item) { source.duration = nil }
        return source
    }

    static func base(of item: String) -> Float {
        Float(names.firstIndex(of: item)! * 1000)
    }
}
