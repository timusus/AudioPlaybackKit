import AVFoundation

/// What the speaker is doing, sent as `TransportEvent.status` only when it changes.
public enum TransportStatus: Equatable, Sendable {
    case paused
    /// Waiting for decode: after a `setCurrent`, `seek` or recovery until its first audio is written,
    /// playing or paused, or asked to play with decode behind the clock.
    case buffering
    case playing
    /// Everything set has been heard. Not final: a later `setNext` plays on from here.
    case ended
}

/// What a `Transport` reports, in the order it happened.
public enum TransportEvent<Item: Hashable & Sendable>: Sendable {
    /// The first position of the last `setCurrent` or `seek` taken, once its first audio is written,
    /// in seconds of `item`'s media time: where it landed, which may differ from the seconds asked.
    case landed(item: Item, seconds: TimeInterval)
    /// The heard item's length as its source probed it, for the progress bar and Now Playing (nil
    /// when unknown), and its `ItemSource.isSeekable`. Sent when either differs from what was last
    /// sent: before `.landed`, after `.crossed`, or when the source learns it.
    case durationChanged(item: Item, duration: TimeInterval?, isSeekable: Bool)
    /// `item` is now the one at the playhead: the gapless join reached the speaker, or the first
    /// item's audio was written there, playing or paused. `format` is the decoded format its first
    /// audio heard was in, the one the processors run at for it.
    case crossed(item: Item, format: PCMFormat)
    /// `item`, already crossed, is now heard in another decoded format: its source changed format
    /// (`ItemSource.currentFormat`), heard when its audio reaches the speaker, up to 30 s after it was decoded, or a seek or
    /// re-feed landed on audio in another format. media3 `AnalyticsListener.onAudioInputFormatChanged`,
    /// but sent when heard rather than decoded.
    case formatChanged(item: Item, format: PCMFormat)
    case status(TransportStatus)
    /// A `setCurrent` or `seek` was taken, in call order, before anything it caused: events before it
    /// predate the call, and the call's first audio is the next `.landed`. Every call is
    /// answered, so a caller can count its calls. `applied` is false for a seek ignored because `item`
    /// has passed: it changed nothing, so what came before it still stands.
    case sought(item: Item, seconds: TimeInterval, applied: Bool)
    /// `item`'s source or processors failed, or the output refused audio (`item` nil). A next item not
    /// yet heard is dropped and the current one plays on. Otherwise playback pauses, and `play()` does
    /// nothing until a `seek`, `setCurrent` or `setProcessors`.
    case failed(item: Item?, error: any Error)
    /// A failed renderer or a media-services reset was rebuilt, and playback restarted paused at the
    /// heard position: the transport dropped play on its own, so a caller tracking play intent
    /// clears it. `play()` carries on. Sent on every recovery, playing or not.
    case recovered
}

/// What is heard, read from `Transport.position`.
public struct TransportPosition<Item: Hashable & Sendable>: Equatable, Sendable {
    public var item: Item
    /// Seconds of `item`'s media time; frames a processor dropped are skipped when they would have played.
    public var seconds: TimeInterval
}

/// The one thing an app drives (ADR-0018): a current item, optionally a next item joined
/// gaplessly at each item's own format, a processor chain, and play, pause, speed and seek.
///
/// Threading: every method may be called from any thread and returns at once. The work runs in call
/// order on the transport's serial queue, never the caller's (a flush blocks about 75 ms and a rate
/// change about 45 ms on device), and events arrive on that queue in order.
///
/// `Item` is whatever the app names a queue entry with. It may repeat (a track on repeat); events
/// carry it back, and a seek to a repeated item lands in the earliest one still set.
///
/// Positions are seconds here and frames at the item's own rate below (ADR-0019): a start or seek
/// becomes the nearest frame once the item's source has opened, so it stays sample-accurate
/// (ADR-0009) and a reported position seeks back to the frame it came from.
///
/// `@unchecked Sendable`: mutable state is confined to its serial `queue`, except the discontinuity
/// count, last buffered-ahead value and position snapshot, which `discontinuityLock` guards for the
/// caller's threads.
public final class Transport<Item: Hashable & Sendable>: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PlaybackRender.Transport", qos: .userInitiated)
    private let output: any AudioOutput
    private let timer: any PumpTimer
    private let sequencer: Sequencer
    private let onEvent: @Sendable (TransportEvent<Item>) -> Void
    private var upstream: SequencedUpstream!
    private var feeder: Feeder!
    /// `setCurrent` and `seek` calls made, counted on the caller's thread; the queue counts those it has
    /// taken in `takenDiscontinuities`, and a position computed while they differ predates a call.
    private let discontinuityLock = NSLock()
    private var calledDiscontinuities = 0
    /// Under `discontinuityLock`: a call zeroes it on the caller's thread, and a pump that predates
    /// the call cannot write the buffer it discards back.
    private var lastBufferedAhead: TimeInterval = 0
    /// Under `discontinuityLock`: the feeder's map as of the last queue entry, and the last read.
    private var published: (snapshot: PositionSnapshot, ids: [Int: Item], epoch: Int)?
    private var lastRead: (id: Int, epoch: Int, seconds: TimeInterval)?
    private var lastObserverKey = 0

    // Confined to `queue`.
    private var lastID = 0
    /// The sequencer's window, by id: ids rise in play order. It follows every change the sequencer
    /// reports and never holds an item the sequencer has dropped, so a seek to one is always valid.
    private var ids: [Int: Item] = [:]
    private var failed = false
    private var takenDiscontinuities = 0
    /// A `setCurrent` or seek was taken and its first position not yet sent as `.landed`.
    private var landingPending = false
    private var sentDuration: (id: Int, duration: TimeInterval?, isSeekable: Bool)?
    private var observers = TimeObservers<Item>()

    /// Seconds of the media decoded and queued past what is heard, as of the last pump; any thread. While decode keeps up, as much as the output
    /// takes, at most 30 s; less near the end of what is set.
    /// 0 from the return of a `setCurrent` or `seek`, and after any flush, until a pump refills it.
    public var bufferedAhead: TimeInterval {
        discontinuityLock.withLock { lastBufferedAhead }
    }

    /// What is heard now, computed from the output clock on the caller's thread with no hop to the
    /// queue (ADR-0031). Nil from the return of a `setCurrent` or `seek` until the queue takes it, and
    /// while nothing is set. Within an item and one call it never goes back, so deltas are listening time.
    public var position: TransportPosition<Item>? {
        discontinuityLock.withLock {
            guard let published, published.epoch == calledDiscontinuities,
                  let position = published.snapshot.position(
                      currentTime: output.currentTime(), outputLatency: output.outputLatency),
                  let item = published.ids[position.item] else { return nil }
            var seconds = position.seconds
            // The clock steps back on a re-anchor or a latency change; the snapshot's floor is only as new as its pump.
            if let lastRead, lastRead.id == position.item, lastRead.epoch == published.epoch {
                seconds = max(seconds, lastRead.seconds)
            }
            lastRead = (position.item, published.epoch, seconds)
            return TransportPosition(item: item, seconds: seconds)
        }
    }

    /// Calls `callback` on the transport's queue every `interval` of output time while the clock runs,
    /// on multiples of it. The output plays at rate 1 (ADR-0030), so at any speed it is wall time.
    /// It arms a wakeup only while registered: the transport polls nothing for itself.
    public func addPeriodicObserver(
        interval: TimeInterval,
        using callback: @escaping @Sendable () -> Void
    ) -> TimeObserverToken {
        precondition(interval > 0 && interval.isFinite)
        return addObserver { $0.addPeriodic(key: $1, interval: interval, callback) }
    }

    /// Calls `callback` on the transport's queue with the heard item and the time when playback
    /// crosses one of `times` (seconds of the heard item's media time). A load, seek or crossing that
    /// lands past a time does not fire it, as media3 `PlayerMessage.setPosition` on a later position.
    public func addBoundaryObserver(
        times: [TimeInterval],
        using callback: @escaping @Sendable (Item, TimeInterval) -> Void
    ) -> TimeObserverToken {
        addObserver { $0.addBoundary(key: $1, times: times, callback) }
    }

    // The key is taken on the caller's thread, so a cancel queued behind the add always removes it.
    private func addObserver(_ add: @escaping (inout TimeObservers<Item>, Int) -> Void) -> TimeObserverToken {
        let key = discontinuityLock.withLock {
            lastObserverKey += 1
            return lastObserverKey
        }
        run { [self] in add(&observers, key) }
        return TimeObserverToken { [weak self] in
            self?.run { [weak self] in self?.observers.remove(key) }
        }
    }

    /// Plays through the device's audio output (`AVSampleBufferAudioRenderer`). The transport never
    /// touches `AVAudioSession`; whatever drives it owns the session. `onEvent` is called on the transport's queue.
    public convenience init(onEvent: @escaping @Sendable (TransportEvent<Item>) -> Void) {
        self.init(
            output: SampleBufferAudioOutput(),
            timer: DispatchPumpTimer(),
            executor: SerialQueueExecutor(),
            onEvent: onEvent
        )
    }

    @_spi(Testing) public convenience init(
        output: any AudioOutput,
        timer: any PumpTimer,
        executor: any SequencerExecutor,
        onEvent: @escaping @Sendable (TransportEvent<Item>) -> Void
    ) {
        self.init(output: output, timer: timer, executor: executor, stretch: TimeStretch(), onEvent: onEvent)
    }

    init(
        output: any AudioOutput,
        timer: any PumpTimer,
        executor: any SequencerExecutor,
        stretch: TimeStretch,
        onEvent: @escaping @Sendable (TransportEvent<Item>) -> Void
    ) {
        self.output = output
        self.timer = timer
        self.onEvent = onEvent
        // A restart is silent until decode lands and the output event is taken, so neither waits
        // for the next tick.
        sequencer = Sequencer(executor: executor) { timer.wake() }
        // Weak: deinit's teardown runs after the transport is gone, and its events go nowhere.
        // `ids` holds every item the sequencer can still decode, so the id fallback is never handed out.
        upstream = SequencedUpstream(sequencer: sequencer, item: { [weak self] id in
            if let item = self?.ids[id] { return item }
            return id
        }) { [weak self] item, error in
            self?.fail(item: item, error)
        }
        feeder = Feeder(output: output, upstream: upstream, wake: { timer.wake() }, stretch: stretch) { [weak self] in self?.handle($0) }
        timer.start(queue: queue) { [weak self] in self?.pump() }
    }

    /// Dropping the transport stops playback as `stop()` does, without the `.ended` event.
    deinit {
        timer.cancel()
        let upstream = upstream!, feeder = feeder!
        queue.async { Self.tearDown(upstream, feeder) }
    }

    /// Stops playback and forgets every item: decode is interrupted, the output flushed and held, and
    /// `.ended` reported. A `setCurrent` starts again.
    public func stop() {
        run { [self] in
            ids = [:]
            failed = false
            Self.tearDown(upstream, feeder)
            publishBufferedAhead()
        }
    }

    private static func tearDown(_ upstream: SequencedUpstream, _ feeder: Feeder) {
        upstream.stop()
        feeder.stop()
    }

    /// Replaces everything set, next items included, and plays `item` from `startSeconds` once
    /// playing. Audio queued from the item before is dropped.
    public func setCurrent(item: Item, source: any ItemSource, startSeconds: TimeInterval = 0) {
        precondition(startSeconds >= 0 && startSeconds.isFinite)
        callDiscontinuity()
        run { [self] in
            takenDiscontinuities += 1
            let id = newID()
            ids = [id: item]
            failed = false
            landingPending = true
            onEvent(.sought(item: item, seconds: startSeconds, applied: true))
            upstream.setCurrent(item: id, source: source, startSeconds: startSeconds)
            feeder.seek(to: SeekTarget(item: id, offset: .seconds(startSeconds)))
        }
    }

    /// Follows the item heard now with no gap, replacing a next item not yet heard (interrupting its
    /// open). Near the end it joins gaplessly, and after `.ended` it plays on from where the output
    /// stopped. Ignored before a `setCurrent`.
    public func setNext(item: Item, source: any ItemSource) {
        run { [self] in
            guard !ids.isEmpty else { return }
            clearUnheardNext()
            let id = newID()
            ids[id] = item
            forget(sequencer.setNext(item: id, source: source))
        }
    }

    /// Removes the next item unless it is heard already.
    public func clearNext() {
        run { [self] in clearUnheardNext() }
    }

    public func play() {
        run { [self] in
            guard !failed else { return }
            feeder.play()
        }
    }

    public func pause() {
        run { [self] in feeder.pause() }
    }

    /// Speed, with pitch kept: a time-stretch before enqueue, re-fed gaplessly like a processor change
    /// (ADR-0030). Audio already queued within half a second plays at the old speed. Use `pause()` to stop.
    public func setRate(_ rate: Double) {
        precondition(rate > 0, "pause() stops playback")
        run { [self] in feeder.setRate(rate) }
    }

    /// Plays on from `seconds` into `item`, which must be the item heard now or one set after it. A
    /// seek to an item already passed (a `crossed` raced the call) is ignored.
    public func seek(item: Item, toSeconds seconds: TimeInterval) {
        precondition(seconds >= 0 && seconds.isFinite)
        callDiscontinuity()
        run { [self] in
            takenDiscontinuities += 1
            let id = ids.filter { $0.value == item }.keys.min()
            onEvent(.sought(item: item, seconds: seconds, applied: id != nil))
            guard let id else { return }
            failed = false
            landingPending = true
            feeder.seek(to: SeekTarget(item: id, offset: .seconds(seconds)))
        }
    }

    /// Gain applied at once, clamped to 0...1 (non-finite ignored); apps fade by calling it repeatedly.
    public func setVolume(_ volume: Float) {
        guard volume.isFinite else { return }
        queue.async { [self] in output.setVolume(min(max(volume, 0), 1)) }
    }

    /// Replaces the processor chain and re-feeds the audio written past about `resumeDepth` of the
    /// clock, so the new chain is heard within that, not after the up to 30 s already written. The
    /// audio before it keeps playing, so there is no gap and no `buffering` status. If the output
    /// cannot drop it in time the re-feed falls back to a full flush from the heard frame, which
    /// rebuffers briefly. After `.ended` the chain is installed for the next audio but nothing is
    /// re-fed, and after a failure it replays from the heard frame. Each processor's `flush` gets the `Item` whose
    /// frames follow. Call it again after a change that alters a processor's `isActive` or output format.
    public func setProcessors(_ processors: [any AudioProcessor]) {
        run { [self] in
            upstream.setProcessors(processors)
            refeedFromHeard()
        }
    }

    /// Re-feeds after an app changed a processor's own parameters (a gain, EQ bands), which apply
    /// from the next chunk processed and so would otherwise wait out the audio already written.
    /// Gapless, as `setProcessors`; calls made while a re-feed is in flight are folded into it, since
    /// the parameters are read when the next chunk is processed. Set a fade through `setVolume`, not
    /// here. Does nothing after a failure, which only a seek, `setCurrent` or `setProcessors` clears.
    public func processorsChanged() {
        run { [self] in
            guard !failed else { return }
            refeedFromHeard()
        }
    }

    private func callDiscontinuity() {
        discontinuityLock.withLock {
            calledDiscontinuities += 1
            lastBufferedAhead = 0
        }
    }

    // MARK: Private, on the queue

    private func newID() -> Int {
        lastID += 1
        return lastID
    }

    // With nothing heard there is nothing written to replace. After `.ended` a re-feed would reopen
    // the source at its end and report the end again.
    private func refeedFromHeard() {
        let position = feeder.heardPosition
        if failed {
            failed = false
            feeder.flush(from: position)
        } else if position != nil, !feeder.hasEnded {
            feeder.refeedAhead()
        }
        publishBufferedAhead()
    }

    /// Every call runs here, so the timer is re-armed for whatever it changed.
    private func run(_ body: @escaping () -> Void) {
        queue.async { [self] in
            body()
            schedule()
        }
    }

    private func pump() {
        feeder.pump()
        publishBufferedAhead()
        schedule()
    }

    /// After every queue entry: publishes what a read maps the clock through, fires the observers due
    /// and arms the one-shot timer for the next clock-driven work, or nothing. The output plays at
    /// rate 1 (ADR-0030), so output seconds are wall seconds.
    private func schedule() {
        let snapshot = feeder.positionSnapshot
        let current = discontinuityLock.withLock {
            published = (snapshot, ids, takenDiscontinuities)
            return calledDiscontinuities == takenDiscontinuities
        }
        if current, let floor = snapshot.floor { sendDurationIfChanged(of: floor.item) }
        let clock = feeder.isClockRunning ? output.currentTime() : nil
        var heard: TimeObservers<Item>.Heard?
        if current, let position = snapshot.position(currentTime: output.currentTime(), outputLatency: output.outputLatency),
           let item = ids[position.item] {
            heard = .init(id: position.item, item: item, seconds: position.seconds, epoch: takenDiscontinuities)
        }
        let deadlines = observers.fire(clock: clock, heard: heard) { feeder.heardTime(of: $0, atSeconds: $1) }
        timer.arm(after: feeder.nextDeadline(also: deadlines).map { $0 - output.currentTime() })
    }

    /// After every pump and flush. Skipped while a `setCurrent` or `seek` is queued, as `report` is:
    /// the call discards this buffer.
    private func publishBufferedAhead() {
        let ahead = feeder.bufferedAhead
        discontinuityLock.withLock {
            if calledDiscontinuities == takenDiscontinuities { lastBufferedAhead = ahead }
        }
    }

    /// The first position of a taken call is its landing. One computed while a `setCurrent` or `seek`
    /// is still queued is dropped: its caller has moved past it.
    private func report(_ position: MediaPositionMap.Position) {
        guard landingPending, discontinuityLock.withLock({ calledDiscontinuities }) == takenDiscontinuities,
              let item = ids[position.item] else { return }
        landingPending = false
        sendDurationIfChanged(of: position.item)
        onEvent(.landed(item: item, seconds: position.seconds))
    }

    private func sendDurationIfChanged(of id: Int) {
        guard let item = ids[id] else { return }
        let duration = sequencer.duration(of: id), isSeekable = sequencer.isSeekable(id)
        if let sent = sentDuration, sent.id == id, sent.duration == duration, sent.isSeekable == isSeekable { return }
        sentDuration = (id, duration, isSeekable)
        onEvent(.durationChanged(item: item, duration: duration, isSeekable: isSeekable))
    }

    /// Once decode has passed into the next its audio may be queued, so it is dropped and the output
    /// re-fed from the heard frame, as media3 `MediaPeriodQueue.removeAfter` drops a read-ahead period.
    /// Before that the sequencer swaps it with no flush.
    private func clearUnheardNext() {
        let change = sequencer.clearNext()
        forget(change)
        guard change == .unchanged, let last = ids.keys.max() else { return }
        _ = dropUnheard(last)
    }

    /// Drops `id` and re-feeds from the heard frame if its audio may be queued; false, changing
    /// nothing, once `id` is heard. The heard frame is read once: the clock may cross into `id`
    /// after it, and a re-read would seek to the item just dropped.
    private func dropUnheard(_ id: Int) -> Bool {
        guard let heard = feeder.heardPosition, id > heard.item else { return false }
        ids[id] = nil
        if !upstream.drop(item: id) {
            feeder.flush(from: heard)
            publishBufferedAhead()
        }
        return true
    }

    private func forget(_ change: Sequencer.TailChange) {
        switch change {
        case let .replaced(id), let .removed(id): ids[id] = nil
        case .appended, .unchanged: break
        }
    }

    private func handle(_ event: FeederEvent) {
        switch event {
        case let .heard(.item(id, format)):
            // Nothing can seek behind the item now heard, so the sequencer may forget those.
            upstream.release(before: id)
            ids = ids.filter { $0.key >= id }
            if let item = ids[id] { onEvent(.crossed(item: item, format: format)) }
        case let .heard(.format(id, format)):
            if let item = ids[id] { onEvent(.formatChanged(item: item, format: format)) }
        case let .position(position):
            report(position)
        case let .status(status):
            onEvent(.status(TransportStatus(status)))
        case let .failed(error):
            failed = true
            onEvent(.failed(item: nil, error: error))
        case .recovered:
            onEvent(.recovered)
        }
    }

    /// A next item decode reached early is reported and dropped while the current plays on
    /// (ADR-0019); the app decides what follows. Only the heard item's failure pauses.
    private func fail(item id: Int, _ error: any Error) {
        onEvent(.failed(item: ids[id], error: error))
        guard let current = feeder.heardPosition?.item, id > current else { return halt() }
        // Deferred: this runs inside the feeder's fill, which a flush would re-enter. By then a call
        // may have dropped `id`, or the clock reached it and it fails as the heard item.
        run { [self] in
            guard ids[id] != nil, !dropUnheard(id) else { return }
            halt()
        }
    }

    private func halt() {
        failed = true
        feeder.halt()
    }
}

private extension TransportStatus {
    init(_ status: FeederStatus) {
        switch status {
        case .paused: self = .paused
        case .buffering: self = .buffering
        case .playing: self = .playing
        case .ended: self = .ended
        }
    }
}
