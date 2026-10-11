import Foundation

/// Float32 interleaved PCM at its item's native rate and channel count; it may change between
/// enqueues, at a join (ADR-0018).
public struct PCMFormat: Hashable, Sendable {
    public var sampleRate: Double
    public var channelCount: Int

    public init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

enum AudioOutputEvent: Equatable, Sendable {
    /// The output dropped everything queued from `at` on (a route or category change); the caller
    /// re-feeds from that time.
    case autoFlushed(at: TimeInterval)
    /// The output stopped consuming audio until the next `flush()`; its clock no longer tracks
    /// what is heard.
    case stalled
    /// The renderer failed or the media services were reset: nothing queued will play and only
    /// `rebuild()` brings the output back.
    case failed(any Error)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.autoFlushed(a), .autoFlushed(b)): a == b
        case (.stalled, .stalled): true
        case let (.failed(a), .failed(b)): a as NSError == b as NSError
        default: false
        }
    }
}

enum AudioOutputError: Error, Equatable {
    case formatRejected(PCMFormat)
    /// The renderer is in its terminal failed state; `rebuild()` replaces it.
    case rendererFailed
}

/// The one edge to the platform renderer: the ASBAR + synchronizer adapter, or a fake in tests.
/// Times are seconds on the output timeline the caller stamps its enqueues on.
///
/// Heard time is `currentTime() - outputLatency`: an adapter whose clock already includes the latency (macOS) reports 0.
///
/// Every call is synchronous. On device `flush()` blocks about 75 ms and `setRate` about 45 ms, so
/// callers keep them off the main thread; the output does no threading of its own. The output
/// reports neither an underrun (its clock runs on) nor a timestamp hole (silence) or overlap
/// (the later audio is trimmed), so the caller stamps contiguous times and watches the clock.
protocol AudioOutput: AnyObject, Sendable {
    func enqueue(_ samples: [Float], format: PCMFormat, at time: TimeInterval) throws
    func flush()
    /// Rate 0 pauses. A `time` re-anchors the clock there (a seek); nil keeps it running from
    /// where it is (resume or speed change).
    func setRate(_ rate: Double, at time: TimeInterval?)
    /// Gain on what is heard now, 0...1: it acts on audio already queued, unlike a processor.
    func setVolume(_ volume: Float)
    func currentTime() -> TimeInterval
    var outputLatency: TimeInterval { get }
    var isReadyForMoreData: Bool { get }
    /// Replaces a failed renderer with a fresh one, keeping volume and settings. Everything queued
    /// is gone and the clock starts again from 0 at rate 0. No event from before it is sent after it.
    func rebuild() throws
    /// Called on any thread.
    func setEventHandler(_ handler: @escaping @Sendable (AudioOutputEvent) -> Void)
}
