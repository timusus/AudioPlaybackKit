import Foundation
@_spi(Testing) import PlaybackRender

/// An `AudioOutput` on a manual clock, with the renderer's measured timing (ADR-0018): a timestamp
/// hole plays as silence, an overlap is rejected (the renderer trims it silently, which would hide a
/// feeder bug), audio stamped behind the clock never plays, and the clock runs on through an underrun with no event. It is ready for more until
/// `capacity` is enqueued ahead of its clock, and a `routeDepth` models a deep route such as AirPlay.
public final class FakeAudioOutput: @unchecked Sendable {
    public struct Enqueue: Equatable, Sendable {
        public var samples: [Float]
        public var format: PCMFormat
        public var time: TimeInterval
    }

    /// An enqueue stamped before the end of what is queued; the renderer would trim it silently.
    public struct OverlapError: Error, Equatable, Sendable {
        public var time: TimeInterval
        public var queuedEnd: TimeInterval

        public init(time: TimeInterval, queuedEnd: TimeInterval) {
            (self.time, self.queuedEnd) = (time, queuedEnd)
        }
    }

    public enum Played: Equatable, Sendable {
        case audio(start: TimeInterval, format: PCMFormat, samples: [Float])
        case silence(start: TimeInterval, duration: TimeInterval)
    }

    public struct RateChange: Equatable, Sendable {
        public var time: TimeInterval
        public var rate: Double
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
    // End of everything enqueued since the last flush, played or not: an enqueue must start at or after it.
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
    private var _partialFlushes: [TimeInterval] = []
    private var _failsPartialFlushes = false
    private var _partialFlushHorizon: TimeInterval = 0
    private var _holdsPartialFlushes = false
    private var heldCompletions: [(completion: @Sendable (Bool) -> Void, succeeded: Bool)] = []
    private var _enqueuesDuringPartialFlush = 0
    private var _played: [Played] = []
    private var _rateChanges: [RateChange] = []
    private var _events: [AudioOutputEvent] = []
    private var stepAfterRead: TimeInterval?
    private var _capacity: TimeInterval = 2
    private var _routeDepth: TimeInterval = 0
    private var _dropped = 0
    private var requested = false

    public init() {}

    /// Seconds of clock time the output takes ahead of its clock before it stops being ready.
    public var capacity: TimeInterval {
        get { locked { _capacity } }
        set { locked { _capacity = newValue } }
    }

    /// While the clock runs, audio enqueued with less than this ahead of it is accepted but never
    /// plays, as a route that buffers this deep drops what reaches it late.
    public var routeDepth: TimeInterval {
        get { locked { _routeDepth } }
        set { locked { _routeDepth = newValue } }
    }

    /// Enqueues the route dropped.
    public var dropped: Int { locked { _dropped } }

    public var enqueues: [Enqueue] { locked { _enqueues } }
    /// The clock time of each flush, injected auto-flushes included.
    public var flushes: [TimeInterval] { locked { _flushes } }
    /// The cut time of each partial flush, failed ones included.
    public var partialFlushes: [TimeInterval] { locked { _partialFlushes } }
    /// Enqueues made between a partial flush and its completion, which the contract forbids.
    public var enqueuesDuringPartialFlush: Int { locked { _enqueuesDuringPartialFlush } }
    public var played: [Played] { locked { _played } }
    /// Each `setRate`, with the clock time it took effect at.
    public var rateChanges: [RateChange] { locked { _rateChanges } }
    @_spi(Testing) public var events: [AudioOutputEvent] { locked { _events } }
    public var rate: Double { locked { _rate } }
    /// The output's gain, which a flush leaves alone as the renderer's does.
    public var volume: Float { locked { _volume } }

    /// Every partial flush reports failure and drops nothing, as the renderer does when it cannot keep the cut.
    public var failsPartialFlushes: Bool {
        get { locked { _failsPartialFlushes } }
        set { locked { _failsPartialFlushes = newValue } }
    }

    /// A partial flush fails, dropping nothing, unless its cut is at least this far past the clock: the
    /// part the renderer has committed to render cannot be replaced, as on the iPhone speaker.
    public var partialFlushHorizon: TimeInterval {
        get { locked { _partialFlushHorizon } }
        set { locked { _partialFlushHorizon = newValue } }
    }

    /// Partial flush completions wait for `completePartialFlushes()` instead of running at once.
    public var holdsPartialFlushes: Bool {
        get { locked { _holdsPartialFlushes } }
        set { locked { _holdsPartialFlushes = newValue } }
    }

    public var outputLatency: TimeInterval {
        get { locked { _outputLatency } }
        set { locked { _outputLatency = newValue } }
    }

    public func enqueue(_ samples: [Float], format: PCMFormat, at time: TimeInterval) throws {
        try locked {
            guard !rendererFailed else { throw AudioOutputError.rendererFailed }
            guard !rejected.contains(format) else { throw AudioOutputError.formatRejected(format) }
            if let end = timelineEnd, time < end - 1e-9 { throw OverlapError(time: time, queuedEnd: end) }
            if !heldCompletions.isEmpty { _enqueuesDuringPartialFlush += 1 }
            _enqueues.append(Enqueue(samples: samples, format: format, time: time))
            // Without a route depth, the part of a late buffer still ahead of the clock plays.
            if _routeDepth > 0, _rate > 0, time - clock < _routeDepth {
                _dropped += 1
                // Taken as far as the output knows: it fills its capacity like audio that plays.
                let end = Buffer(start: time, format: format, samples: samples).end
                timelineEnd = max(timelineEnd ?? end, end)
                return
            }
            let buffer = Buffer(start: time, format: format, samples: samples)
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
        sendReadyIfRequested()
    }

    public func flush(fromTime time: TimeInterval, completion: @escaping @Sendable (Bool) -> Void) {
        let (succeeded, hold) = locked { () -> (Bool, Bool) in
            _partialFlushes.append(time)
            // A cut the clock has passed is not one the renderer can make.
            let succeeded = !_failsPartialFlushes && time > clock && time >= clock + _partialFlushHorizon
            if succeeded {
                // A buffer that straddles the cut is kept whole: the pessimistic case for the caller.
                queue.removeAll { $0.start >= time }
                timelineEnd = queue.map(\.end).max()
            }
            if _holdsPartialFlushes { heldCompletions.append((completion, succeeded)) }
            return (succeeded, _holdsPartialFlushes)
        }
        sendReadyIfRequested()
        if !hold { completion(succeeded) }
    }

    /// Runs the held partial flush completions, oldest first.
    public func completePartialFlushes() {
        let held = locked { () -> [(completion: @Sendable (Bool) -> Void, succeeded: Bool)] in
            defer { heldCompletions = [] }
            return heldCompletions
        }
        for entry in held { entry.completion(entry.succeeded) }
    }

    public func setRate(_ rate: Double, at time: TimeInterval?) {
        locked {
            _rate = rate
            if let time { clock = time }
            _rateChanges.append(RateChange(time: clock, rate: rate))
        }
        sendReadyIfRequested()
    }

    public var isReadyForMoreMediaData: Bool { locked { ready } }

    public func requestMediaDataWhenReady() {
        locked { requested = true }
        sendReadyIfRequested()
    }

    public func setVolume(_ volume: Float) {
        locked { _volume = volume }
    }

    public func currentTime() -> TimeInterval {
        let (time, step) = locked {
            defer { stepAfterRead = nil }
            return (clock, stepAfterRead)
        }
        if let step { advance(by: step) }
        return time
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
            requested = false
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
        sendReadyIfRequested()
    }

    /// Advances by `seconds` just after the next `currentTime()` read, as a live clock moves on
    /// between two reads of one call.
    public func advanceAfterNextRead(by seconds: TimeInterval) {
        locked { stepAfterRead = seconds }
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

    // Under the lock.
    private var ready: Bool {
        (timelineEnd ?? clock) - clock < _capacity
    }

    /// Sends the one requested `.readyForMoreMediaData` once the output is ready, outside the lock.
    private func sendReadyIfRequested() {
        let handler: (@Sendable (AudioOutputEvent) -> Void)? = locked {
            guard requested, ready else { return nil }
            requested = false
            _events.append(.readyForMoreMediaData)
            return self.handler
        }
        handler?(.readyForMoreMediaData)
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
