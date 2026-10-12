import AVFoundation

public enum TransportStatus: Equatable, Sendable {
    case paused
    /// Waiting for decode: after a `setCurrent`, `seek` or recovery until its first audio is written,
    /// playing or paused, or asked to play with decode behind the clock.
    case buffering
    case playing
    /// Everything set has been heard. Not final: a later `setNext` plays on from here.
    case ended
}

public enum TransportEvent<Item: Hashable & Sendable>: Sendable {
    /// What is heard now, in seconds of `item`'s media time. Sent when it changes, at most once a
    /// pump; frames a processor dropped are skipped when they would have played. Within an item it
    /// never goes back except on a `seek` or `setCurrent`, so position deltas are listening time.
    /// None computed before a `seek` or `setCurrent` is sent once that call has returned.
    /// `duration` is the item's length as its source probed it, for the progress bar and Now
    /// Playing; nil when unknown. `isSeekable` is the source's `ItemSource.isSeekable`.
    case position(item: Item, seconds: TimeInterval, duration: TimeInterval?, isSeekable: Bool)
    /// `item` is now the one at the playhead: the gapless join reached the speaker, or the first
    /// item's audio was written there, playing or paused. `format` is the item's decoded format, the
    /// one the processors run at for it.
    case crossed(item: Item, format: PCMFormat)
    case status(TransportStatus)
    /// A `setCurrent` or `seek` was taken, in call order, before anything it caused: events before it
    /// predate the call, and the next `.position` for `item` is the call's first audio. Every call is
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

/// Gap between pumps. The feeder's 0.5 s `resumeDepth` is playout time at any rate, so even a pump
/// the OS coalesces to twice this never starves the output.
let pumpInterval: TimeInterval = 0.1

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

    // Confined to `queue`.
    private var lastID = 0
    /// The sequencer's window, by id: ids rise in play order. It follows every change the sequencer
    /// reports and never holds an item the sequencer has dropped, so a seek to one is always valid.
    private var ids: [Int: Item] = [:]
    private var failed = false
    private var takenDiscontinuities = 0

    /// Seconds of the media decoded and queued past what is heard, as of the last pump (every
    /// `pumpInterval`); any thread. About two seconds while decode keeps up, less near the end of what is set.
    /// 0 from the return of a `setCurrent` or `seek`, and after any flush, until a pump refills it.
    public var bufferedAhead: TimeInterval {
        discontinuityLock.withLock { lastBufferedAhead }
    }

    /// Plays through the device's audio output (`AVSampleBufferAudioRenderer`). The transport never
    /// touches `AVAudioSession`; whatever drives it owns the session. `onEvent` is called on the transport's queue.
    ///
    /// `timePitchAlgorithm` is how speed keeps pitch: `.timeDomain` (the default) had the shortest
    /// dropout on a speed change on the iPhone probe (97 ms to 2x, 140 ms back); `.spectral` suits music.
    public convenience init(
        timePitchAlgorithm: AVAudioTimePitchAlgorithm = .timeDomain,
        onEvent: @escaping @Sendable (TransportEvent<Item>) -> Void
    ) {
        self.init(
            output: SampleBufferAudioOutput(timePitchAlgorithm: timePitchAlgorithm),
            timer: DispatchPumpTimer(),
            executor: SerialQueueExecutor(),
            onEvent: onEvent
        )
    }

    @_spi(Testing) public init(
        output: any AudioOutput,
        timer: any PumpTimer,
        executor: any SequencerExecutor,
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
        feeder = Feeder(output: output, upstream: upstream, wake: { timer.wake() }) { [weak self] in self?.handle($0) }
        timer.start(interval: pumpInterval, queue: queue) { [weak self] in self?.pump() }
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
        queue.async { [self] in
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
        queue.async { [self] in
            takenDiscontinuities += 1
            let id = newID()
            ids = [id: item]
            failed = false
            onEvent(.sought(item: item, seconds: startSeconds, applied: true))
            upstream.setCurrent(item: id, source: source, startSeconds: startSeconds)
            feeder.seek(to: SeekTarget(item: id, offset: .seconds(startSeconds)))
        }
    }

    /// Follows the item heard now with no gap, replacing a next item not yet heard (interrupting its
    /// open). Near the end it joins gaplessly, and after `.ended` it plays on from where the output
    /// stopped. Ignored before a `setCurrent`.
    public func setNext(item: Item, source: any ItemSource) {
        queue.async { [self] in
            guard !ids.isEmpty else { return }
            clearUnheardNext()
            let id = newID()
            ids[id] = item
            forget(sequencer.setNext(item: id, source: source))
        }
    }

    /// Removes the next item unless it is heard already.
    public func clearNext() {
        queue.async { [self] in clearUnheardNext() }
    }

    public func play() {
        queue.async { [self] in
            guard !failed else { return }
            feeder.play()
        }
    }

    public func pause() {
        queue.async { [self] in feeder.pause() }
    }

    /// Speed, with pitch kept; the output plays media time at `rate`. Use `pause()` to stop.
    public func setRate(_ rate: Double) {
        precondition(rate > 0, "pause() stops playback")
        queue.async { [self] in feeder.setRate(rate) }
    }

    /// Plays on from `seconds` into `item`, which must be the item heard now or one set after it. A
    /// seek to an item already passed (a `crossed` raced the call) is ignored.
    public func seek(item: Item, toSeconds seconds: TimeInterval) {
        precondition(seconds >= 0 && seconds.isFinite)
        callDiscontinuity()
        queue.async { [self] in
            takenDiscontinuities += 1
            let id = ids.filter { $0.value == item }.keys.min()
            onEvent(.sought(item: item, seconds: seconds, applied: id != nil))
            guard let id else { return }
            failed = false
            feeder.seek(to: SeekTarget(item: id, offset: .seconds(seconds)))
        }
    }

    /// Gain applied at once, clamped to 0...1 (non-finite ignored); apps fade by calling it repeatedly.
    public func setVolume(_ volume: Float) {
        guard volume.isFinite else { return }
        queue.async { [self] in output.setVolume(min(max(volume, 0), 1)) }
    }

    /// Replaces the processor chain without a flush: the old chain drains into what is queued and
    /// the new one applies from the next chunk, heard about two seconds on. Each processor's `flush`
    /// gets the `Item` whose frames follow. Call it again after a
    /// change that alters a processor's `isActive` or output format; other parameters apply live.
    /// After a failure it re-feeds from the heard frame instead, since nothing is playing.
    public func setProcessors(_ processors: [any AudioProcessor]) {
        queue.async { [self] in
            upstream.setProcessors(processors)
            guard failed else { return }
            failed = false
            feeder.flush(from: feeder.heardPosition)
            publishBufferedAhead()
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

    private func pump() {
        feeder.pump()
        publishBufferedAhead()
    }

    /// After every pump and flush. Skipped while a `setCurrent` or `seek` is queued, as `report` is:
    /// the call discards this buffer.
    private func publishBufferedAhead() {
        let ahead = feeder.bufferedAhead
        discontinuityLock.withLock {
            if calledDiscontinuities == takenDiscontinuities { lastBufferedAhead = ahead }
        }
    }

    /// Every frame position comes from audio already pulled, so its item's rate is known. One computed
    /// while a `setCurrent` or `seek` is still queued is dropped: its caller has moved past it.
    private func report(_ position: MediaPositionMap.Position) {
        guard discontinuityLock.withLock({ calledDiscontinuities }) == takenDiscontinuities,
              let item = ids[position.item], let rate = upstream.formats[position.item]?.sampleRate else { return }
        let duration = sequencer.duration(of: position.item).map { Double($0) / rate }
        let isSeekable = sequencer.isSeekable(position.item)
        onEvent(.position(item: item, seconds: Double(position.mediaFrame) / rate, duration: duration, isSeekable: isSeekable))
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
        case let .crossed(id):
            // Nothing can seek behind the item now heard, so the sequencer may forget those.
            upstream.release(before: id)
            ids = ids.filter { $0.key >= id }
            // Its first chunk was pulled before it was heard, so its format is known.
            if let item = ids[id], let format = upstream.formats[id] { onEvent(.crossed(item: item, format: format)) }
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
        queue.async { [self] in
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
