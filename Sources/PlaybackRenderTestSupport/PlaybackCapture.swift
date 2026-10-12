import Foundation
@_spi(Testing) import PlaybackRender

/// Everything a run put through a `Transport` and `FakeAudioOutput`, for a golden dump (media3's
/// `CapturingAudioSink` with `PlaybackOutput`): the buffers that reached the output, what it played,
/// the flushes and the transport events, in the order each happened within its own list.
public struct PlaybackCapture: Sendable {
    public struct Buffer: Sendable {
        public var time: TimeInterval
        public var format: PCMFormat
        public var samples: [Float]
    }

    public struct Played: Sendable {
        public var start: TimeInterval
        /// Nil for silence.
        public var format: PCMFormat?
        public var duration: TimeInterval
        public var samples: [Float]
    }

    public var buffers: [Buffer]
    public var played: [Played]
    public var flushes: [TimeInterval]
    public var rateChanges: [FakeAudioOutput.RateChange]
    /// One line per `TransportEvent`, without the error text, which is not stable across systems.
    public var events: [String]
}

/// Collects a transport's events; hand `record` to `Transport(onEvent:)`.
public final class PlaybackCaptureRecorder<Item: Hashable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []

    public init() {}

    public func record(_ event: TransportEvent<Item>) {
        lock.withLock { _events.append(Self.describe(event)) }
    }

    public func capture(of output: FakeAudioOutput) -> PlaybackCapture {
        PlaybackCapture(
            buffers: output.enqueues.map { .init(time: $0.time, format: $0.format, samples: $0.samples) },
            played: output.played.map {
                switch $0 {
                case let .audio(start, format, samples):
                    .init(start: start, format: format,
                          duration: Double(samples.count / format.channelCount) / format.sampleRate, samples: samples)
                case let .silence(start, duration):
                    .init(start: start, format: nil, duration: duration, samples: [])
                }
            },
            flushes: output.flushes,
            rateChanges: output.rateChanges,
            events: lock.withLock { _events }
        )
    }

    private static func describe(_ event: TransportEvent<Item>) -> String {
        switch event {
        case let .position(item, seconds, duration, isSeekable):
            "position \(item) \(seconds) duration=\(duration.map { "\($0)" } ?? "nil") seekable=\(isSeekable)"
        case let .crossed(item, format):
            "crossed \(item) \(format.sampleRate)Hz x\(format.channelCount)"
        case let .status(status):
            "status \(status)"
        case let .sought(item, seconds, applied):
            "sought \(item) \(seconds) applied=\(applied)"
        case let .failed(item, error):
            "failed \(item.map { "\($0)" } ?? "nil") \(type(of: error))"
        case .recovered:
            "recovered"
        }
    }
}
