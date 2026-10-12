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
    /// `duration` is the item's length as its source probed it, for the progress bar and Now
    /// Playing; nil when unknown. `isSeekable` is the source's `ItemSource.isSeekable`.
    case position(item: Item, seconds: TimeInterval, duration: TimeInterval?, isSeekable: Bool)
    /// `item` is now the one at the playhead: the gapless join reached the speaker, or the first
    /// item's audio was written there, playing or paused.
    case crossed(item: Item)
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

/// The one thing an app drives (ADR-0018): a current item, optionally one or more next items joined
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

    // Confined to `queue`.
    private var lastID = 0
    /// The sequencer's window, by id: ids rise in play order. It follows every change the sequencer
    /// reports and never holds an item the sequencer has dropped, so a seek to one is always valid.
    private var ids: [Int: Item] = [:]
    private var failed = false

    /// Plays through the device's audio output (`AVSampleBufferAudioRenderer`). The transport never
    /// touches `AVAudioSession`: on iOS the app sets the category and activates the session before
    /// `play()`, and handles interruptions. `onEvent` is called on the transport's queue.
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
            Self.tearDown(upstream, feeder)
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
        queue.async { [self] in
            let id = newID()
            ids = [id: item]
            failed = false
            onEvent(.sought(item: item, seconds: startSeconds, applied: true))
            upstream.setCurrent(item: id, source: source, startSeconds: startSeconds)
            feeder.seek(to: SeekTarget(item: id, offset: .seconds(startSeconds)))
        }
    }

    /// Follows the last item set with no gap. Replaces the last next item if decode has not reached
    /// it yet or is still opening it (interrupting the open); once it has decoded some (decode runs a
    /// few seconds ahead), `item` is queued after it instead.
    /// Never flushes: near the end it joins gaplessly, and after `.ended` it plays on from where the
    /// output stopped. Ignored before a `setCurrent`.
    public func setNext(item: Item, source: any ItemSource) {
        queue.async { [self] in
            guard !ids.isEmpty else { return }
            let id = newID()
            ids[id] = item
            forget(sequencer.setNext(item: id, source: source))
        }
    }

    /// Removes the last next item unless decode has already decoded some of it; then it still plays, and
    /// the app seeks or calls `setCurrent` to drop it.
    public func clearNext() {
        queue.async { [self] in forget(sequencer.clearNext()) }
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
        queue.async { [self] in
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
            feeder.flush()
        }
    }

    // MARK: Private, on the queue

    private func newID() -> Int {
        lastID += 1
        return lastID
    }

    private func pump() {
        feeder.pump()
    }

    /// Every frame position comes from audio already pulled, so its item's rate is known.
    private func report(_ position: MediaPositionMap.Position) {
        guard let item = ids[position.item], let rate = upstream.sampleRates[position.item] else { return }
        let duration = sequencer.duration(of: position.item).map { Double($0) / rate }
        let isSeekable = sequencer.isSeekable(position.item)
        onEvent(.position(item: item, seconds: Double(position.mediaFrame) / rate, duration: duration, isSeekable: isSeekable))
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
            if let item = ids[id] { onEvent(.crossed(item: item)) }
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
        if let current = feeder.currentItem, id > current {
            ids[id] = nil
            // Deferred: this runs inside the feeder's fill, which a flush would re-enter.
            if !upstream.drop(item: id) { queue.async { [self] in feeder.flush() } }
            return
        }
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
