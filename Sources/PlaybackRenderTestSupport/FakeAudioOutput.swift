import Foundation
@_spi(Testing) import PlaybackRender

/// An `AudioOutput` on a manual clock, with the renderer's measured timing (ADR-0018): a timestamp
/// hole plays as silence, an overlap trims the later audio, audio stamped behind the clock never
/// plays, and the clock runs on through an underrun with no event.
public final class FakeAudioOutput: @unchecked Sendable {
    public struct Enqueue: Equatable, Sendable {
        public var samples: [Float]
        public var format: PCMFormat
        public var time: TimeInterval
    }

    public enum Played: Equatable, Sendable {
        case audio(start: TimeInterval, format: PCMFormat, samples: [Float])
        case silence(start: TimeInterval, duration: TimeInterval)
    }

    private struct Buffer {
        var start: TimeInterval
        var format: PCMFormat
        var samples: [Float]
        var end: TimeInterval { start + Double(samples.count / format.channelCount) / format.sampleRate }
    }

    private let lock = NSLock()
    private var clock: TimeInterval = 0
    private var _rate: Double = 0
    private var _volume: Float = 1
    private var _outputLatency: TimeInterval = 0
    private var queue: [Buffer] = []
    // End of everything enqueued since the last flush, played or not: an overlap is trimmed to it.
    private var timelineEnd: TimeInterval?
    private var stalled = false
    // A failed renderer: silent, and every enqueue throws until `rebuild()`.
    private var rendererFailed = false
    private var rebuildError: (any Error)?
    private var _rebuilds = 0
    private var rejected: Set<PCMFormat> = []
    private var handler: (@Sendable (AudioOutputEvent) -> Void)?
    private var _enqueues: [Enqueue] = []
    private var _flushes: [TimeInterval] = []
    private var _played: [Played] = []
    private var _events: [AudioOutputEvent] = []

    /// Ready for more while less than this much is queued ahead of the clock.
    public let readyAhead: TimeInterval

    public init(readyAhead: TimeInterval = 1) {
        self.readyAhead = readyAhead
    }

    public var enqueues: [Enqueue] { locked { _enqueues } }
    /// The clock time of each flush, injected auto-flushes included.
    public var flushes: [TimeInterval] { locked { _flushes } }
    public var played: [Played] { locked { _played } }
    @_spi(Testing) public var events: [AudioOutputEvent] { locked { _events } }
    public var rate: Double { locked { _rate } }
    /// The output's gain, which a flush leaves alone as the renderer's does.
    public var volume: Float { locked { _volume } }

    public var outputLatency: TimeInterval {
        get { locked { _outputLatency } }
        set { locked { _outputLatency = newValue } }
    }

    public func enqueue(_ samples: [Float], format: PCMFormat, at time: TimeInterval) throws {
        try locked {
            guard !rendererFailed else { throw AudioOutputError.rendererFailed }
            guard !rejected.contains(format) else { throw AudioOutputError.formatRejected(format) }
            _enqueues.append(Enqueue(samples: samples, format: format, time: time))
            var buffer = Buffer(start: time, format: format, samples: samples)
            if let end = timelineEnd, time < end {
                let trimmed = min(frameCount(end - time, format), samples.count / format.channelCount)
                buffer.samples.removeFirst(trimmed * format.channelCount)
                buffer.start += Double(trimmed) / format.sampleRate
            }
            timelineEnd = max(timelineEnd ?? buffer.end, buffer.end)
            if !buffer.samples.isEmpty { queue.append(buffer) }
        }
    }

    public func flush() {
        locked {
            _flushes.append(clock)
            queue = []
            timelineEnd = nil
            stalled = false
        }
    }

    public func setRate(_ rate: Double, at time: TimeInterval?) {
        locked {
            _rate = rate
            if let time { clock = time }
        }
    }

    public func setVolume(_ volume: Float) {
        locked { _volume = volume }
    }

    public func currentTime() -> TimeInterval { locked { clock } }

    public var isReadyForMoreData: Bool {
        locked { (timelineEnd ?? clock) - clock < readyAhead }
    }

    /// A fresh renderer: nothing queued, the clock at 0 and stopped. The volume is kept, as the
    /// adapter re-applies it.
    public func rebuild() throws {
        try locked {
            _rebuilds += 1
            if let rebuildError { throw rebuildError }
            clock = 0
            _rate = 0
            queue = []
            timelineEnd = nil
            stalled = false
            rendererFailed = false
        }
    }

    @_spi(Testing) public func setEventHandler(_ handler: @escaping @Sendable (AudioOutputEvent) -> Void) {
        locked { self.handler = handler }
    }

    // MARK: Test controls

    /// Moves wall time on by `seconds`; the clock moves `rate` times as far, playing what is queued.
    public func advance(by seconds: TimeInterval) {
        locked {
            let from = clock, to = clock + seconds * _rate
            guard to > from else { return }
            clock = to
            guard !stalled, !rendererFailed else { return record(.silence(start: from, duration: to - from)) }
            var cursor = from
            while let buffer = queue.first, buffer.start < to {
                let start = max(cursor, buffer.start), end = min(buffer.end, to)
                if start < end {
                    if start > cursor { record(.silence(start: cursor, duration: start - cursor)) }
                    let first = frameCount(start - buffer.start, buffer.format)
                    let last = frameCount(end - buffer.start, buffer.format)
                    let channels = buffer.format.channelCount
                    record(.audio(
                        start: buffer.start + Double(first) / buffer.format.sampleRate,
                        format: buffer.format,
                        samples: Array(buffer.samples[(first * channels)..<(last * channels)])
                    ))
                    cursor = end
                }
                guard buffer.end <= to else { break }
                queue.removeFirst()
            }
            if cursor < to { record(.silence(start: cursor, duration: to - cursor)) }
        }
    }

    /// The route-change auto-flush: drops everything queued and reports the flush time, by default
    /// the clock. A notification can arrive late, with the flush time behind the clock.
    public func injectAutoFlush(at time: TimeInterval? = nil) {
        let (time, handler) = locked {
            let time = time ?? clock
            _flushes.append(clock)
            queue = []
            timelineEnd = nil
            _events.append(.autoFlushed(at: time))
            return (time, self.handler)
        }
        handler?(.autoFlushed(at: time))
    }

    /// The iPhone synchronizer's clock steps back tens of milliseconds on a rate change or a resume.
    public func stepClockBack(by seconds: TimeInterval) {
        locked { clock -= seconds }
    }

    /// The output plays silence until the next `flush()`, with its clock still running.
    public func injectStall() {
        let handler = locked {
            stalled = true
            _events.append(.stalled)
            return self.handler
        }
        handler?(.stalled)
    }

    /// The renderer fails: it goes silent and every enqueue throws until `rebuild()`. `reported`
    /// sends `.failed` as the status observer does; without it the next enqueue is the first sign.
    public func injectFailure(_ error: (any Error)? = nil, reported: Bool = true) {
        let error = error ?? AudioOutputError.rendererFailed
        let handler = locked {
            rendererFailed = true
            guard reported else { return nil as (@Sendable (AudioOutputEvent) -> Void)? }
            _events.append(.failed(error))
            return self.handler
        }
        handler?(.failed(error))
    }

    /// The media-services reset: the renderer is dead as in `injectFailure`, but the event names none.
    public func injectReset() {
        let handler = locked {
            rendererFailed = true
            _events.append(.mediaServicesReset)
            return self.handler
        }
        handler?(.mediaServicesReset)
    }

    /// Every later `rebuild()` throws `error`.
    public func failRebuilds(with error: any Error) {
        locked { rebuildError = error }
    }

    public var rebuilds: Int { locked { _rebuilds } }

    public func reject(_ format: PCMFormat) {
        locked { _ = rejected.insert(format) }
    }

    private func frameCount(_ seconds: TimeInterval, _ format: PCMFormat) -> Int {
        Int((seconds * format.sampleRate).rounded())
    }

    // Coalesces with the previous span when contiguous, so a test compares what was heard, not
    // how `advance` was sliced.
    private func record(_ span: Played) {
        switch (_played.last, span) {
        case let (.audio(start, format, samples)?, .audio(next, nextFormat, more))
            where format == nextFormat
            && abs(start + Double(samples.count / format.channelCount) / format.sampleRate - next) < 1e-9:
            _played[_played.count - 1] = .audio(start: start, format: format, samples: samples + more)
        case let (.silence(start, duration)?, .silence(next, more)) where abs(start + duration - next) < 1e-9:
            _played[_played.count - 1] = .silence(start: start, duration: duration + more)
        default:
            _played.append(span)
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

@_spi(Testing) extension FakeAudioOutput: AudioOutput {}
