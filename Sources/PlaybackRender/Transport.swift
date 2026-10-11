import Foundation

public enum TransportStatus: Equatable, Sendable {
    case paused
    /// Asked to play, waiting for decode to get ahead of the clock.
    case buffering
    case playing
    /// Everything set has been heard. Not final: a later `setNext` plays on from here.
    case ended
}

public enum TransportEvent<Item: Hashable & Sendable>: Sendable {
    /// What is heard now, as a media frame of `item` at its own `sampleRate`. Sent when it changes,
    /// at most once a pump; frames a processor dropped are skipped when they would have played.
    /// Within an item it never goes back except on a `seek` or `setCurrent`, so position deltas are
    /// listening time.
    case position(item: Item, frame: Int64, sampleRate: Double)
    /// `item` is now the one at the playhead: the gapless join reached the speaker, or the first
    /// item's audio was written there, playing or paused.
    case crossed(item: Item)
    case status(TransportStatus)
    /// Playback paused on an error. `item` is the item whose source or processors failed, nil when
    /// the output refused audio. `play()` does nothing until a `seek`, `setCurrent` or `setProcessors`.
    case failed(item: Item?, error: any Error)
}

/// Gap between pumps. The output plays at most this times the rate between refills (0.3 s at 3x),
/// under the feeder's 0.5 s `resumeDepth`, so the pump's cadence alone never starves it.
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
/// Positions are frames at the item's own rate, the unit every layer below keeps: seeks are
/// sample-accurate (ADR-0009) and a start frame needs no rate before the item is opened. Position
/// events carry the rate for converting to seconds.
public final class Transport<Item: Hashable & Sendable>: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PlaybackRender.Transport", qos: .userInitiated)
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
    /// A position reported before its item's first chunk gave the rate; sent once the rate is known.
    private var unratedPosition: MediaPositionMap.Position?

    /// Plays through the device's audio output (`AVSampleBufferAudioRenderer`). The transport never
    /// touches `AVAudioSession`: on iOS the app sets the category and activates the session before
    /// `play()`, and handles interruptions. `onEvent` is called on the transport's queue.
    public convenience init(onEvent: @escaping @Sendable (TransportEvent<Item>) -> Void) {
        self.init(output: SampleBufferAudioOutput(), onEvent: onEvent)
    }

    init(
        output: any AudioOutput,
        timer: any PumpTimer = DispatchPumpTimer(),
        executor: any SequencerExecutor = SerialQueueExecutor(),
        onEvent: @escaping @Sendable (TransportEvent<Item>) -> Void
    ) {
        self.timer = timer
        self.onEvent = onEvent
        sequencer = Sequencer(executor: executor)
        // Weak: deinit's teardown runs after the transport is gone, and its events go nowhere.
        upstream = SequencedUpstream(sequencer: sequencer) { [weak self] item, error in
            self?.fail(item: item, error)
        }
        feeder = Feeder(output: output, upstream: upstream) { [weak self] in self?.handle($0) }
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
            unratedPosition = nil
            Self.tearDown(upstream, feeder)
        }
    }

    private static func tearDown(_ upstream: SequencedUpstream, _ feeder: Feeder) {
        upstream.stop()
        feeder.stop()
    }

    /// Replaces everything set, next items included, and plays `item` from `startFrame` once
    /// playing. Audio queued from the item before is dropped.
    public func setCurrent(item: Item, source: any ItemSource, startFrame: Int64 = 0) {
        precondition(startFrame >= 0)
        queue.async { [self] in
            let id = newID()
            ids = [id: item]
            failed = false
            upstream.setCurrent(item: id, source: source, startFrame: startFrame)
            feeder.seek(to: MediaPositionMap.Position(item: id, mediaFrame: startFrame))
        }
    }

    /// Follows the last item set with no gap. Replaces the last next item if decode has not reached
    /// it yet; once it has (decode runs a few seconds ahead), `item` is queued after it instead.
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

    /// Removes the last next item unless decode has already reached it; then it still plays, and
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

    /// Plays on from `frame` of `item`, which must be the item heard now or one set after it. A seek
    /// to an item already passed (a `crossed` raced the call) is ignored.
    public func seek(item: Item, toFrame frame: Int64) {
        precondition(frame >= 0)
        queue.async { [self] in
            guard let id = ids.filter({ $0.value == item }).keys.min() else { return }
            failed = false
            feeder.seek(to: MediaPositionMap.Position(item: id, mediaFrame: frame))
        }
    }

    /// Replaces the processor chain, applied from what is heard now by re-feeding (a flush). Call it
    /// again after a change that alters a processor's `isActive` or output format.
    public func setProcessors(_ processors: [any AudioProcessor]) {
        queue.async { [self] in
            upstream.setProcessors(processors)
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
        // The feeder reports a position once, so one that came before its rate goes out now.
        if let position = unratedPosition { report(position) }
    }

    private func report(_ position: MediaPositionMap.Position) {
        unratedPosition = nil
        guard let item = ids[position.item] else { return }
        guard let rate = upstream.sampleRates[position.item] else {
            unratedPosition = position
            return
        }
        onEvent(.position(item: item, frame: position.mediaFrame, sampleRate: rate))
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
        }
    }

    private func fail(item id: Int, _ error: any Error) {
        failed = true
        onEvent(.failed(item: ids[id], error: error))
        feeder.pause()
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
