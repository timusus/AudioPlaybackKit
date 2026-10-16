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

@_spi(Testing) public enum AudioOutputEvent: Equatable, Sendable {
    /// The output dropped everything queued from `at` on (a route or category change), or its
    /// output configuration changed so queued audio is stale; the caller re-feeds from that time.
    case autoFlushed(at: TimeInterval)
    /// The output stopped consuming audio until the next `flush()`; its clock no longer tracks
    /// what is heard. `SampleBufferAudioOutput` cannot detect this, so only the fake sends it; the
    /// feeder handles it for an output that can.
    case stalled
    /// The renderer failed: nothing queued will play and only `rebuild()` brings the output back.
    case failed(any Error)
    /// The media services were reset. Unlike `.failed` it names no renderer and arrives once per
    /// reset, so it may follow a failure the caller already recovered from; `rebuild()` answers it.
    case mediaServicesReset
    /// The output can take more audio, once per `requestMediaDataWhenReady()`.
    case readyForMoreMediaData

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.autoFlushed(a), .autoFlushed(b)): a == b
        case (.stalled, .stalled), (.mediaServicesReset, .mediaServicesReset),
             (.readyForMoreMediaData, .readyForMoreMediaData): true
        case let (.failed(a), .failed(b)): a as NSError == b as NSError
        default: false
        }
    }
}

@_spi(Testing) public enum AudioOutputError: Error, Equatable {
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
@_spi(Testing) public protocol AudioOutput: AnyObject, Sendable {
    func enqueue(_ samples: [Float], format: PCMFormat, at time: TimeInterval) throws
    func flush()
    /// Rate 0 pauses. A `time` re-anchors the clock there (a seek); nil keeps it running from
    /// where it is (resume or speed change).
    func setRate(_ rate: Double, at time: TimeInterval?)
    /// Gain on what is heard now, 0...1: it acts on audio already queued, unlike a processor.
    func setVolume(_ volume: Float)
    func currentTime() -> TimeInterval
    var outputLatency: TimeInterval { get }
    /// Whether the output wants more audio now. The output decides how far ahead of its clock it
    /// buffers; a deep route such as AirPlay drops audio that arrives with less than its depth to spare.
    var isReadyForMoreMediaData: Bool { get }
    /// Sends `.readyForMoreMediaData` once, as soon as the output is ready; repeated calls arm it once.
    func requestMediaDataWhenReady()
    /// Replaces a failed renderer with a fresh one, keeping volume and settings. Everything queued
    /// is gone and the clock starts again from 0 at rate 0. No event from before it is sent after it.
    func rebuild() throws
    /// Called on any thread.
    func setEventHandler(_ handler: @escaping @Sendable (AudioOutputEvent) -> Void)
}
