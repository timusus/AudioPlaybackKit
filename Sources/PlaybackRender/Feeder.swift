import Foundation

enum UpstreamSupply: Sendable {
    case chunk(TaggedChunk)
    /// Nothing ready yet; the feeder asks again on its next pump.
    case pending
    case ended
}

/// What the feeder pulls from, called on its queue.
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
    case heard(MediaPositionMap.Heard)
    case position(MediaPositionMap.Position)
    case status(FeederStatus)
    /// The output refused a chunk. The feeder has paused and pulls nothing more until the next flush
    /// or seek.
    case failed(any Error)
    /// The output was rebuilt and the feeder restarted with `playWhenReady` false.
    case recovered
}

/// Moves tagged chunks from upstream into an `AudioOutput`: stamps them contiguously, writes while
/// the output is ready for more, pauses through an underrun and re-feeds after any flush (ADR-0018).
/// It knows nothing of items beyond the tags.
///
/// The output decides how far ahead it buffers, as media3's `DefaultAudioSink` writes while its
/// `AudioTrack` takes data: a deep route such as AirPlay drops audio that reaches it late.
///
/// Speed is a time-stretch before enqueue and the output always plays at rate 1 (ADR-0030), so every
/// depth is output time, which is wall time.
///
/// Threading: confined to the caller's one serial queue; output events, on any thread, wait in an inbox
/// that the next `pump()` drains, and call `wake` so the caller pumps now.
final class Feeder {
    /// Output seconds written ahead of the clock however much the output takes, under media3's 50 s
    /// `maxBufferMs`. It bounds time, not bytes: about 11 MB at 48 kHz
    /// stereo Float32, several times that at a high sample rate or channel count.
    static let maxDepth: TimeInterval = 30
    /// Depth at which an output starts after an underrun, as media3's `bufferForPlaybackAfterRebufferMs`,
    /// so a flaky stream gives one longer pause, not a run of short stalls.
    let rebufferDepth: TimeInterval
    /// Depth at which a buffering output starts, first or after a seek, re-feed or pause; well under
    /// `rebufferDepth` so a slow upstream still starts promptly.
    let resumeDepth: TimeInterval

    private let output: AudioOutput
    private let upstream: FeederUpstream
    private let onEvent: (FeederEvent) -> Void
    private let inbox = RestartInbox()
    private let wake: @Sendable () -> Void

    private var map = MediaPositionMap()
    private var rate: Double = 1
    private var stretch: TimeStretch
    private var playWhenReady = false
    private var outputRunning = false
    /// The clock the last pump's underrun/end check judged at, or the clock after a restart that left it behind.
    private var pumpedAt = -TimeInterval.infinity
    private var upstreamEnded = false
    /// The current buffering began as an underrun, so it waits for `rebufferDepth`, not `resumeDepth`.
    private var afterUnderrun = false
    private var failed = false
    /// Set by a renderer recovery and cleared on `.playing`: a second failure in between surfaces
    /// instead of rebuilding again, as media3's `pendingRecoverableRendererError` allows one retry.
    private var recovering = false
    // Where the last restart asked upstream to start, the position until audio of that epoch is written.
    private var restartTarget: SeekTarget?
    private var reportedPosition: MediaPositionMap.Position?
    private var status = FeederStatus.paused
    /// The partial flush awaiting its completion. Nothing is pulled or written meanwhile, so calls
    /// that arrive in between coalesce into it: processors run at pull time and apply to the next chunk.
    private var pendingPartialFlush: PendingFlush?
    private var lastPartialFlush = 0
    /// What a failed flush must put back, and whether an underrun hold rewound the clock meanwhile.
    private struct PendingFlush {
        var token: Int
        var before: MediaPositionMap
        var chunkEnds: [TimeInterval]
        var upstreamEnded: Bool
        var resume: MediaPositionMap.Position
        var held = false
    }
    /// Where each written chunk ends, ascending and pruned behind the playhead: the map merges
    /// contiguous chunks, and a partial flush must cut between them.
    private var chunkEnds: [TimeInterval] = []
    /// Diagnostics: the flush whose re-feed is being timed, until its first buffer and `resumeDepth` are logged.
    private var refeedTrace: (label: String, began: DispatchTime, firstEnqueued: Bool)?

    init(
        output: AudioOutput,
        upstream: FeederUpstream,
        rebufferDepth: TimeInterval = 2,
        resumeDepth: TimeInterval = 0.5,
        wake: @escaping @Sendable () -> Void = {},
        stretch: TimeStretch = TimeStretch(),
        onEvent: @escaping (FeederEvent) -> Void
    ) {
        precondition(resumeDepth > 0 && resumeDepth <= rebufferDepth)
        self.stretch = stretch
        self.output = output
        self.upstream = upstream
        self.rebufferDepth = rebufferDepth
        self.resumeDepth = resumeDepth
        self.onEvent = onEvent
        self.wake = wake
        // The map's first epoch starts at 0, so the clock must too.
        output.setRate(0, at: 0)
        let inbox = inbox
        output.setEventHandler { [output] event in
            switch event {
            // The flush time is where the output dropped audio, not a clock reading: no latency to take off.
            case let .autoFlushed(at: time): inbox.post(time)
            // A stalled clock stops tracking what is heard, so take the time it stalled at now.
            case .stalled: inbox.post(output.currentTime() - output.outputLatency, stalled: true)
            case let .failed(error): inbox.post(failure: error)
            case .mediaServicesReset: inbox.postReset()
            case .readyForMoreMediaData: break
            }
            // The output is silent until a pump restarts it, or wants more than the last pump wrote.
            wake()
        }
    }

    // MARK: Transport

    func play() {
        playWhenReady = true
        // With enough queued it plays on at once: reporting buffering first would flicker the app's `isPlaying`.
        if status == .paused, !canStart { setStatus(.buffering) }
        pump()
    }

    func pause() {
        playWhenReady = false
        // As media3 resets isRebuffering on a playWhenReady change: the next start is a plain one.
        afterUnderrun = false
        if outputRunning {
            output.setRate(0, at: nil)
            outputRunning = false
        }
        // Waiting for audio stays buffering: media3 reports STATE_BUFFERING whatever playWhenReady is.
        if status == .playing { setStatus(.paused) }
    }

    /// Speed, stretched from the next chunk pulled; what is queued past `resumeDepth` is re-fed at it
    /// like a processor change, so changes while one is pending fold into it.
    func setRate(_ rate: Double) {
        precondition(rate > 0, "pause() stops playback")
        guard rate != self.rate else { return }
        note("feeder setRate old=\(self.rate) new=\(rate) running=\(outputRunning)")
        self.rate = rate
        if !hasEnded { refeedAhead() }
    }

    /// The one place the reported position may go back within an item.
    func seek(to target: SeekTarget) {
        reportedPosition = nil
        restart(from: target)
        pump()
    }

    /// Re-feeds from `position`, a `heardPosition` the caller resolved, e.g. so a reconfigured
    /// pipeline applies to what is queued. Taken, not re-read: the clock moves on in between.
    func flush(from position: SeekTarget?) {
        restart(from: position)
        pump()
    }

    /// Re-feeds what is written past `resumeDepth` of the clock, so a reconfigured pipeline applies
    /// there without a gap or a `buffering` status. A failed partial flush, or a cut too near the
    /// written end, appends from `writtenEnd` instead. Does nothing while one is pending or when nothing is written past the cut.
    func refeedAhead() {
        // The cut lands on the end of the chunk that straddles the target: a cut inside a chunk
        // would re-feed audio the renderer still holds, and an overlap is trimmed or dropped by it.
        let target = output.currentTime() + resumeDepth
        guard pendingPartialFlush == nil, !failed else { return }
        let before = map, endsBefore = chunkEnds
        // A flush replacing under `resumeDepth` of audio gains less than appending would delay the
        // change, and a cut that close to the tail is inside what a shallow renderer has committed to.
        guard let boundary = chunkEnds.first(where: { $0 >= target }),
              map.writtenEnd - boundary >= resumeDepth,
              let cut = map.truncate(from: boundary) else { return appendAtWrittenEnd() }
        chunkEnds.removeAll { $0 > cut.time }
        lastPartialFlush += 1
        let token = lastPartialFlush
        pendingPartialFlush = PendingFlush(
            token: token, before: before, chunkEnds: endsBefore, upstreamEnded: upstreamEnded, resume: cut.resume
        )
        let inbox = inbox, wake = wake
        note("partialFlush begin cut=\(fixed(cut.time)) sourceResume=\(fixed(cut.resume.seconds))")
        output.flush(fromTime: cut.time) { succeeded in
            inbox.post(partialFlush: token, succeeded: succeeded, at: .now())
            wake()
        }
        pump()
    }

    /// Nothing queued is replaced: the new chain applies from the next chunk pulled, which is stamped at
    /// `writtenEnd`, so the change is heard once the queued audio plays out.
    private func appendAtWrittenEnd() {
        note("processor change appended at writtenEnd")
    }

    /// Flushes and holds the output at rate 0, reporting `.ended`; upstream must supply nothing more.
    func stop() {
        playWhenReady = false
        restart(from: nil, status: .ended)
    }

    /// Output seconds written past the playhead.
    var bufferedAhead: TimeInterval {
        max(map.writtenEnd - playhead(), 0)
    }

    var hasEnded: Bool { status == .ended }

    /// The frame heard now, or where the last restart asked for until its audio is written.
    var heardPosition: SeekTarget? {
        currentPosition(at: playhead())
    }

    // MARK: Tick

    /// All the feeder's work; the caller calls it on its queue at `nextDeadline` and on `wake`.
    func pump() {
        let pending = inbox.drain()
        if pending.reset || pending.failure != nil {
            recover(from: pending.reset ? nil : pending.failure, flushedAt: pending.time)
        } else if let time = pending.time {
            note("restart after \(pending.stalled ? "stall" : "autoFlush") flushTime=\(fixed(time))")
            restart(from: currentPosition(at: max(map.epochStart, time)))
            refeedTrace = (pending.stalled ? "stall" : "autoFlush", .now(), false)
            // A stall is the renderer starving, a downstream underrun; a route change's flush is not.
            // Not while paused: a pause ends the rebuffer even if the stall is drained after it.
            if pending.stalled && playWhenReady { afterUnderrun = true }
        }
        // A restart above cleared the pending flush, so its late completion is stale and ignored here.
        for result in pending.partialFlushes where result.token == pendingPartialFlush?.token {
            guard let flush = pendingPartialFlush else { continue }
            pendingPartialFlush = nil
            if result.succeeded {
                // Resupplied only now: a failed flush leaves the source and the stretch where they were.
                stretch.reset()
                upstream.resupply(from: SeekTarget(flush.resume))
                upstreamEnded = false
                refeedTrace = ("partialFlush", result.completedAt, false)
            } else if flush.held {
                // The hold rewound the clock under the flush, so what the renderer kept is unknown.
                note("partialFlush failed after a hold, full restart")
                restart(from: flush.before.position(at: playhead()).map(SeekTarget.init) ?? heardPosition)
            } else {
                // A failed flush leaves the enqueued buffers unchanged (AVSampleBufferAudioRenderer.flush(fromSourceTime:)).
                map = flush.before
                chunkEnds = flush.chunkEnds
                upstreamEnded = flush.upstreamEnded
                appendAtWrittenEnd()
            }
        }

        // Pause before refilling: audio stamped behind a running clock never plays, and the clock is
        // past the written end one output latency before it is heard, so judge by the clock. At the end
        // of the stream nothing more is written and the hold would report `.ended` early: wait for the playhead.
        let checkedAt = output.currentTime()
        let checkedPlayhead = map.playhead(currentTime: checkedAt, outputLatency: output.outputLatency)
        if outputRunning, (upstreamEnded ? checkedPlayhead : checkedAt) >= map.writtenEnd {
            holdForUnderrun()
            // The end of the stream is no rebuffer: a next item after it starts like a first one.
            if !upstreamEnded {
                note("underrun")
                afterUnderrun = true
                setStatus(.buffering)
            }
        }

        fill()

        if let trace = refeedTrace, trace.firstEnqueued, map.writtenEnd - output.currentTime() >= resumeDepth {
            note("refeed reached resumeDepth after=\(trace.label) sinceMs=\(fixed(milliseconds(since: trace.began)))")
            refeedTrace = nil
        }

        if !outputRunning, status == .buffering || status == .paused, canStart {
            if playWhenReady {
                output.setRate(1, at: nil)
                outputRunning = true
                afterUnderrun = false
                setStatus(.playing)
            } else {
                setStatus(.paused)
            }
        }

        // The check ran before `fill`, so a deadline the clock crossed during it was not judged: it stays armed.
        pumpedAt = min(checkedAt, output.currentTime())
        report()
    }

    /// The output-clock time the next pump is due for work only the clock brings, or nil while the
    /// clock is not running. Everything else the pump waits on (decode landing, the output becoming
    /// ready, a flush completing, a stall or failure) calls `wake`, and a stopped clock only moves
    /// through a call that pumps. The earliest of:
    /// - the underrun, or at the end of the stream the last frame heard, at `writtenEnd`;
    /// - the next item or format reaching the playhead;
    /// - the refill once the 30 s cap has drained by `resumeDepth` (the output's ready event never comes
    ///   when it took everything);
    /// - the next position report, at the next multiple of `pumpInterval` on the clock (the temporary
    ///   position cadence), so a late pump never pushes the reports after it later.
    func nextDeadline() -> TimeInterval? {
        guard outputRunning else { return nil }
        let clock = output.currentTime(), latency = output.outputLatency
        // A clock within 1 % of an interval short of a multiple is at it, so float noise never arms ~0.
        var due = ((clock / pumpInterval + 0.01).rounded(.down) + 1) * pumpInterval
        // Work due by the clock the last pump's check saw was handled: arming it again would spin while the clock is frozen.
        func consider(_ deadline: TimeInterval) {
            if deadline > pumpedAt { due = min(due, deadline) }
        }
        consider(map.writtenEnd + (upstreamEnded ? latency : 0))
        if let boundary = map.nextHeardBoundary(after: playhead()) { consider(boundary + latency) }
        if map.writtenEnd - clock >= Self.maxDepth { consider(map.writtenEnd - Self.maxDepth + resumeDepth) }
        return due
    }

    // MARK: Private

    private var canStart: Bool {
        guard !failed else { return false }
        // At the end nothing more is written, so nothing can land behind the clock: start while
        // anything unheard remains, even with the clock past the written end.
        if upstreamEnded { return map.writtenEnd - playhead() > 0 }
        // From the clock, like the pause and `fill`: a lead over the heard playhead can be nil at the clock.
        let needed = afterUnderrun ? rebufferDepth : resumeDepth
        let lead = map.writtenEnd - output.currentTime()
        if lead >= needed { return true }
        // A rebuffer depth deeper than the output takes would wait forever; a first start or a
        // resume is shallow enough to be reached, so a near-empty output must not start it.
        return afterUnderrun && lead > 0 && !output.isReadyForMoreMediaData
    }

    /// Rewinds the clock to the written end, where the next chunk is stamped; the playhead stays on what is heard.
    private func holdForUnderrun() {
        note("hold at writtenEnd=\(fixed(map.writtenEnd)) status=\(status)")
        map.hold(at: playhead())
        pendingPartialFlush?.held = true
        output.setRate(0, at: map.writtenEnd)
        outputRunning = false
    }

    private func playhead() -> TimeInterval {
        map.playhead(currentTime: output.currentTime(), outputLatency: output.outputLatency)
    }

    private func currentPosition(at playhead: TimeInterval) -> SeekTarget? {
        map.position(at: playhead).map(SeekTarget.init) ?? restartTarget
    }

    /// A restart in seconds is not reported: its first audio carries the frame they became.
    private func reportablePosition(at playhead: TimeInterval) -> MediaPositionMap.Position? {
        if let position = map.position(at: playhead) { return position }
        guard let restartTarget, case let .frame(frame, sampleRate?) = restartTarget.offset else { return nil }
        return MediaPositionMap.Position(item: restartTarget.item, mediaFrame: frame, sampleRate: sampleRate)
    }

    /// The one recovery path: an auto-flush, a stall, a transport flush, a seek and a stop all land here.
    private func restart(from position: SeekTarget?, status: FeederStatus? = nil) {
        // Flush times already posted predate this flush, which covers them; a failure does not.
        _ = inbox.drainTime()
        refeedTrace = nil
        output.flush()
        // Held at rate 0 until `resumeDepth` is written, so the first audio is not stamped behind the clock.
        let anchor = output.currentTime()
        output.setRate(0, at: anchor)
        outputRunning = false
        afterUnderrun = false
        map.reset(at: anchor)
        stretch.reset()
        chunkEnds = []
        upstreamEnded = false
        failed = false
        pendingPartialFlush = nil
        restartTarget = position
        // With no position nothing was consumed, so upstream's next chunk is still the right one.
        if let position { upstream.resupply(from: position) }
        setStatus(status ?? .buffering)
    }

    /// A failed renderer, or a media-services reset (`error` nil): rebuild the output and restart
    /// from what was heard, paused, so the user chooses to play on. A reset always rebuilds, even
    /// mid-recovery: it can follow the failure it caused, and each notification comes once.
    private func recover(from error: (any Error)?, flushedAt time: TimeInterval? = nil) {
        note("recover error=\(error.map { String(describing: $0) } ?? "mediaServicesReset")")
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
    func halt() {
        failed = true
        pendingPartialFlush = nil
        recovering = false
        pause()
        // No audio is coming, so it is not waiting for any.
        if status == .buffering { setStatus(.paused) }
    }

    private func fail(_ error: any Error) {
        halt()
        onEvent(.failed(error))
    }

    /// Pulls even after an end: an end is an underrun with no supply coming, so supply that comes
    /// later (a next item) is written at `writtenEnd` and resumes through the underrun path.
    private func fill() {
        // The lead counts from the clock, not the heard playhead: the renderer drops audio stamped behind its clock.
        while !failed, pendingPartialFlush == nil, map.writtenEnd - output.currentTime() < Self.maxDepth {
            // Its one ready event wakes the pump, so a deep route refills as fast as it drains.
            guard output.isReadyForMoreMediaData else { return output.requestMediaDataWhenReady() }
            let supply = upstream.pull()
            if case .ended = supply {
                guard stretch.finish().allSatisfy(write) else { continue }
                upstreamEnded = true
                return
            }
            if upstreamEnded {
                upstreamEnded = false
                if status == .ended { setStatus(.buffering) }
                // The clock ran on past the end while its audio was still reaching the hardware. Paused
                // too: a pause leaves the clock where it stopped, past the end, and the next play would run on from there.
                if case .chunk = supply, output.currentTime() >= map.writtenEnd {
                    holdForUnderrun()
                    setStatus(.buffering)
                }
            }
            guard case let .chunk(chunk) = supply else { return }
            if rate != stretch.rate { note("stretch rate applied old=\(stretch.rate) new=\(rate)") }
            for stretched in stretch.process(chunk, rate: rate) {
                guard write(stretched) else { break }
            }
        }
    }

    /// False when the output refused it: the feeder restarted or failed, so what follows it is stale.
    private func write(_ chunk: TimeStretch.Chunk) -> Bool {
        if chunk.frameCount > 0 {
            if let trace = refeedTrace, !trace.firstEnqueued {
                refeedTrace?.firstEnqueued = true
                note("refeed first buffer after=\(trace.label) pts=\(fixed(map.writtenEnd)) sinceMs=\(fixed(milliseconds(since: trace.began)))")
            }
            do {
                try output.enqueue(chunk.samples, format: chunk.format, at: map.writtenEnd)
            } catch AudioOutputError.rendererFailed {
                recover(from: AudioOutputError.rendererFailed)
                return false
            } catch {
                fail(error)
                return false
            }
        }
        for span in chunk.spans { map.append(span.tag, format: span.format, outputFrames: span.outputFrames) }
        if chunk.frameCount > 0 { chunkEnds.append(map.writtenEnd) }
        return true
    }

    private func report() {
        let playhead = playhead()
        for heard in map.advance(to: playhead) { onEvent(.heard(heard)) }
        chunkEnds.removeAll { $0 < playhead }
        // Within an item the position only goes forward, as media3's renderers take
        // max(current, new) unless a seek allowed a discontinuity: the clock steps back on a rate
        // change, a resume or a re-anchor, and apps count listening time from position deltas.
        if let position = reportablePosition(at: playhead),
           reportedPosition.map({ $0.item != position.item || $0.seconds < position.seconds }) ?? true {
            reportedPosition = position
            onEvent(.position(position))
        }
        if upstreamEnded, playhead >= map.writtenEnd, status != .ended {
            setStatus(.ended)
        }
    }

    private func note(_ message: String) {
        let clock = output.currentTime()
        let depth = fixed(map.writtenEnd - clock)
        renderLog.notice("\(message, privacy: .public) clock=\(fixed(clock), privacy: .public) depth=\(depth, privacy: .public)")
    }

    private func setStatus(_ status: FeederStatus) {
        guard status != self.status else { return }
        if status == .buffering { note("buffering") }
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
    private var stalled = false
    private var failure: (any Error)?
    private var reset = false
    private var partialFlushes: [(token: Int, succeeded: Bool, completedAt: DispatchTime)] = []

    func post(partialFlush token: Int, succeeded: Bool, at completedAt: DispatchTime) {
        lock.withLock { partialFlushes.append((token, succeeded, completedAt)) }
    }

    func post(_ time: TimeInterval, stalled: Bool = false) {
        lock.withLock {
            self.time = min(self.time ?? time, time)
            self.stalled = self.stalled || stalled
        }
    }

    func post(failure: any Error) {
        lock.withLock { self.failure = self.failure ?? failure }
    }

    func postReset() {
        lock.withLock { reset = true }
    }

    func drain() -> (
        time: TimeInterval?, stalled: Bool, failure: (any Error)?, reset: Bool,
        partialFlushes: [(token: Int, succeeded: Bool, completedAt: DispatchTime)]
    ) {
        lock.withLock {
            defer { (time, stalled, failure, reset, partialFlushes) = (nil, false, nil, false, []) }
            return (time, stalled, failure, reset, partialFlushes)
        }
    }

    func drainTime() -> TimeInterval? {
        lock.withLock {
            defer { (time, stalled) = (nil, false) }
            return time
        }
    }
}
