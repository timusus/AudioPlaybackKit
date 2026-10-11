import Foundation

/// **How far a ``GrowingFileByteSource`` may download ahead of the decoder on an expensive path**
/// (ADR-0013). While the network path is expensive or constrained (cellular, a hotspot, Low Data
/// Mode), the source cancels its request once the frontier is the limit ahead of the decoder's read
/// position, and resumes from the frontier when the decoder comes within half of that. On a cheap
/// path, and for a host that ignores ranges, the file downloads whole.
///
/// The limit is `bytes`, or `seconds` of audio converted with the stream's bitrate once the host has
/// reported the probed duration (``GrowingFileByteSource/streamProbed(duration:)``); until then, and
/// when the length or duration is unknown, `bytes` applies.
public struct GrowingFileReadAhead: Equatable, Sendable {
    public let bytes: Int64
    public let seconds: TimeInterval?

    public init(bytes: Int64) {
        precondition(bytes > 0, "a read-ahead of \(bytes) bytes")
        self.bytes = bytes
        self.seconds = nil
    }

    /// As media3's `DefaultLoadControl`, whose buffer is in time. `fallbackBytes` covers the probe.
    public init(seconds: TimeInterval, fallbackBytes: Int64) {
        precondition(seconds > 0, "a read-ahead of \(seconds) seconds")
        precondition(fallbackBytes > 0, "a read-ahead of \(fallbackBytes) bytes")
        self.bytes = fallbackBytes
        self.seconds = seconds
    }

    static let ceiling: Int64 = 1 << 40

    /// The limit in bytes for a stream of `bitsPerSecond`, else the fallback.
    func limit(bitsPerSecond: Double?) -> Int64 {
        guard let seconds, let bitsPerSecond, bitsPerSecond > 0 else { return bytes }
        // The duration is host input: a tiny one makes an absurd bitrate that must not trap the conversion.
        let bytes = (seconds * bitsPerSecond / 8).rounded()
        return bytes >= Double(Self.ceiling) ? Self.ceiling : max(1, Int64(bytes))
    }
}
