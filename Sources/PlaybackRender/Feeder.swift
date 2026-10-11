import Foundation

enum UpstreamSupply: Sendable {
    case chunk(TaggedChunk)
    /// Nothing ready yet; the feeder asks again on its next pump.
    case pending
    case ended
}

/// What the feeder pulls from: the pipeline, later. Called on the feeder's queue.
protocol FeederUpstream: AnyObject {
    func pull() -> UpstreamSupply
    /// Drop everything buffered and supply again from this point, sample-accurately (ADR-0009).
    func resupply(from target: SeekTarget)
}

enum FeederStatus: Equatable, Sendable {
    case paused
    case buffering
    case playing
    case ended
}

enum FeederEvent {
    case crossed(item: Int)
    case position(MediaPositionMap.Position)
    case status(FeederStatus)
    /// The output refused a chunk. The feeder has paused and pulls nothing more until the next flush
    /// or seek.
    case failed(any Error)
    /// The output was rebuilt and the feeder restarted with `playWhenReady` false.
    case recovered
}

/// Moves tagged chunks from upstream into an `AudioOutput`: stamps them contiguously, keeps
/// `targetDepth` written ahead of the output clock, pauses through an underrun and re-feeds after any
/// flush (ADR-0018). It knows nothing of items beyond the tags.
///
/// Both depths are playout time, wall seconds at the current rate: the time between pumps is wall
/// time, so a depth in media time would shrink at speed until one late pump runs the output dry.
///
/// Threading: confined to the caller's one serial queue; output events, on any thread, wait in an inbox
/// that the next `pump()` drains, and call `wake` so the caller pumps now.
final class Feeder {
    let targetDepth: TimeInterval
    /// Depth at which a buffering output starts again; well under `targetDepth` so a slow upstream
    /// still resumes promptly.
    let resumeDepth: TimeInterval

    private let output: AudioOutput
    private let upstream: FeederUpstream
    private let onEvent: (FeederEvent) -> Void
    private let inbox = RestartInbox()

    private var map = MediaPositionMap()
    private var rate: Double = 1
    private var playWhenReady = false
    private var outputRunning = false
    private var upstreamEnded = false
    private var failed = false
    /// Set by a renderer recovery and cleared on `.playing`: a second failure in between surfaces
    /// instead of rebuilding again, as media3's `pendingRecoverableRendererError` allows one retry.
    private var recovering = false
    // Where the last restart asked upstream to start, the position until audio of that epoch is written.
    private var restartTarget: SeekTarget?
    private var reportedPosition: MediaPositionMap.Position?
    private var status = FeederStatus.paused

    init(
        output: AudioOutput,
        upstream: FeederUpstream,
        targetDepth: TimeInterval = 2,
        resumeDepth: TimeInterval = 0.5,
        wake: @escaping @Sendable () -> Void = {},
        onEvent: @escaping (FeederEvent) -> Void
    ) {
        precondition(resumeDepth > 0 && resumeDepth <= targetDepth)
        self.output = output
        self.upstream = upstream
        self.targetDepth = targetDepth
        self.resumeDepth = resumeDepth
        self.onEvent = onEvent
        // The map's first epoch starts at 0, so the clock must too.
        output.setRate(0, at: 0)
        let inbox = inbox
        output.setEventHandler { [output] event in
            switch event {
            // The flush time is where the output dropped audio, not a clock reading: no latency to take off.
            case let .autoFlushed(at: time): inbox.post(time)
            // A stalled clock stops tracking what is heard, so take the time it stalled at now.
            case .stalled: inbox.post(output.currentTime() - output.outputLatency)
            case let .failed(error): inbox.post(failure: error)
            case .mediaServicesReset: inbox.postReset()
            }
            // The output is silent until a pump restarts it.
            wake()
        }
    }

    // MARK: Transport

    func play() {
        playWhenReady = true
        if status == .paused { setStatus(.buffering) }
        pump()
    }

    func pause() {
        playWhenReady = false
        if outputRunning {
            output.setRate(0, at: nil)
            outputRunning = false
        }
        if status != .ended { setStatus(.paused) }
    }

    /// Speed. The map needs no checkpoint: the output plays media time at any rate.
    func setRate(_ rate: Double) {
        precondition(rate > 0, "pause() stops playback")
        self.rate = rate
        if outputRunning { output.setRate(rate, at: nil) }
        // The depths scale with the rate, so refill now: the next tick plays faster than the last fill
        // allowed for. Paused, `play()` pumps.
        if playWhenReady { pump() }
    }

    /// The one place the reported position may go back within an item.
    func seek(to target: SeekTarget) {
        reportedPosition = nil
        restart(from: target)
        pump()
    }

    /// Re-feeds from the heard position, e.g. so a reconfigured pipeline applies to what is queued.
    func flush() {
        restart(from: currentPosition(at: playhead()))
        pump()
    }

    /// Flushes and holds the output at rate 0, reporting `.ended`; upstream must supply nothing more.
    func stop() {
        playWhenReady = false
        restart(from: nil, status: .ended)
    }

    /// The item heard now, or the one the last restart asked for until its audio is written.
    var currentItem: Int? {
        currentPosition(at: playhead())?.item
    }

    // MARK: Tick

    /// All the feeder's work; the caller calls it on its queue from a timer or the output's
    /// ready-for-more callback, often enough that `resumeDepth` outlasts the gap between calls.
    func pump() {
        let pending = inbox.drain()
        if pending.reset || pending.failure != nil {
            recover(from: pending.reset ? nil : pending.failure, flushedAt: pending.time)
        } else if let time = pending.time {
            restart(from: currentPosition(at: max(map.epochStart, time)))
        }

        // Pause before refilling: audio stamped behind a running clock never plays. Only once the
        // written end is heard, so the clock runs one output latency past it.
        if outputRunning, playhead() >= map.writtenEnd {
            output.setRate(0, at: map.writtenEnd)
            map.holdAtWrittenEnd()
            outputRunning = false
            if !upstreamEnded { setStatus(.buffering) }
        }

        fill()

        let depth = map.writtenEnd - playhead()
        if playWhenReady, !outputRunning, !failed, status == .buffering,
           upstreamEnded ? depth > 0 : depth >= resumeDepth * rate {
            output.setRate(rate, at: nil)
            outputRunning = true
            setStatus(.playing)
        }

        report()
    }

    // MARK: Private

    private func playhead() -> TimeInterval {
        map.playhead(currentTime: output.currentTime(), outputLatency: output.outputLatency)
    }

    private func currentPosition(at playhead: TimeInterval) -> SeekTarget? {
        map.position(at: playhead).map(SeekTarget.init) ?? restartTarget
    }

    /// A restart in seconds is not reported: its first audio carries the frame they became.
    private func reportablePosition(at playhead: TimeInterval) -> MediaPositionMap.Position? {
        if let position = map.position(at: playhead) { return position }
        guard let restartTarget, case let .frame(frame) = restartTarget.offset else { return nil }
        return MediaPositionMap.Position(item: restartTarget.item, mediaFrame: frame)
    }

    /// The one recovery path: an auto-flush, a stall, a transport flush, a seek and a stop all land here.
    private func restart(from position: SeekTarget?, status: FeederStatus? = nil) {
        // Flush times already posted predate this flush, which covers them; a failure does not.
        _ = inbox.drainTime()
        output.flush()
        // Held at rate 0 until `resumeDepth` is written, so the first audio is not stamped behind the clock.
        let anchor = output.currentTime()
        output.setRate(0, at: anchor)
        outputRunning = false
        map.reset(at: anchor)
        upstreamEnded = false
        failed = false
        restartTarget = position
        // With no position nothing was consumed, so upstream's next chunk is still the right one.
        if let position { upstream.resupply(from: position) }
        setStatus(status ?? (playWhenReady ? .buffering : .paused))
    }

    /// A failed renderer, or a media-services reset (`error` nil): rebuild the output and restart
    /// from what was heard, paused, so the user chooses to play on. A reset always rebuilds, even
    /// mid-recovery: it can follow the failure it caused, and each notification comes once.
    private func recover(from error: (any Error)?, flushedAt time: TimeInterval? = nil) {
        if let error, recovering { return fail(error) }
        let heard = min(time ?? .infinity, playhead())
        let position = currentPosition(at: max(map.epochStart, heard))
        recovering = true
        playWhenReady = false
        do {
            try output.rebuild()
        } catch {
            return fail(error)
        }
        // Whatever the old renderer posted is answered by this rebuild.
        _ = inbox.drain()
        restart(from: position)
        onEvent(.recovered)
    }

    /// Pauses and pulls nothing more until the next restart, which re-arms one recovery.
    private func fail(_ error: any Error) {
        failed = true
        recovering = false
        pause()
        onEvent(.failed(error))
    }

    /// Pulls even after an end: an end is an underrun with no supply coming, so supply that comes
    /// later (a next item) is written at `writtenEnd` and resumes through the underrun path.
    private func fill() {
        // The lead counts from the clock, not the heard playhead: the renderer drops audio stamped behind its clock.
        while !failed, map.writtenEnd - output.currentTime() < targetDepth * rate {
            let supply = upstream.pull()
            if case .ended = supply {
                upstreamEnded = true
                return
            }
            if upstreamEnded {
                upstreamEnded = false
                if status == .ended { setStatus(playWhenReady ? .buffering : .paused) }
            }
            guard case let .chunk(chunk) = supply else { return }
            write(chunk)
        }
    }

    private func write(_ chunk: TaggedChunk) {
        if chunk.frameCount > 0 {
            do {
                try output.enqueue(chunk.samples, format: chunk.format, at: map.writtenEnd)
            } catch AudioOutputError.rendererFailed {
                return recover(from: AudioOutputError.rendererFailed)
            } catch {
                return fail(error)
            }
        }
        for tag in chunk.tags { map.append(tag, sampleRate: chunk.format.sampleRate) }
    }

    private func report() {
        let playhead = playhead()
        for item in map.advance(to: playhead) { onEvent(.crossed(item: item)) }
        // Within an item the position only goes forward, as media3's renderers take
        // max(current, new) unless a seek allowed a discontinuity: the clock steps back on a rate
        // change, a resume or a re-anchor, and apps count listening time from position deltas.
        if let position = reportablePosition(at: playhead),
           reportedPosition.map({ $0.item != position.item || $0.mediaFrame < position.mediaFrame }) ?? true {
            reportedPosition = position
            onEvent(.position(position))
        }
        if upstreamEnded, playhead >= map.writtenEnd, status != .ended {
            setStatus(.ended)
        }
    }

    private func setStatus(_ status: FeederStatus) {
        guard status != self.status else { return }
        self.status = status
        if status == .playing { recovering = false }
        onEvent(.status(status))
    }
}

/// Output events reduced to the output time to restart from, heard rather than clock time (the
/// earliest wins), and the first renderer failure since the last drain.
private final class RestartInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval?
    private var failure: (any Error)?
    private var reset = false

    func post(_ time: TimeInterval) {
        lock.withLock { self.time = min(self.time ?? time, time) }
    }

    func post(failure: any Error) {
        lock.withLock { self.failure = self.failure ?? failure }
    }

    func postReset() {
        lock.withLock { reset = true }
    }

    func drain() -> (time: TimeInterval?, failure: (any Error)?, reset: Bool) {
        lock.withLock {
            defer { (time, failure, reset) = (nil, nil, false) }
            return (time, failure, reset)
        }
    }

    func drainTime() -> TimeInterval? {
        lock.withLock {
            defer { time = nil }
            return time
        }
    }
}
