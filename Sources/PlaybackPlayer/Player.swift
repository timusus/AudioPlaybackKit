import AVFoundation
import Foundation
import Observation
import PlaybackRender

/// An ordered list of the app's items played through one `Transport`, with media3 `Player`'s model:
/// `playWhenReady` is the app's intent, `state` is what the transport reports, and the two never
/// write each other (ADR-0019).
///
/// The list is the app's, in play order. The player keys `Transport` by a private entry id per
/// position, so an item may appear twice. As soon as an item is current the one after it is armed
/// with `setNext`, and every edit that changes what follows re-arms it.
@MainActor @Observable
public final class Player<Item: Hashable & Sendable> {
    private struct Entry {
        let id: Int
        let item: Item
    }

    public private(set) var items: [Item] = []
    public private(set) var currentIndex: Int?
    public var currentItem: Item? { currentIndex.map { items[$0] } }

    public private(set) var state = PlaybackState.idle {
        didSet { updateRebuffering() }
    }
    public private(set) var suppression = PlaybackSuppression.unsuppressed {
        didSet { updateRebuffering() }
    }
    public var isPlaying: Bool { Self.isPlaying(state: state, playWhenReady: playWhenReady, suppression: suppression) }
    /// The failure that ended the current item; nil while playback is healthy.
    public private(set) var error: PlaybackError?

    /// What is heard, in seconds of the current item's media time, computed from the output clock on
    /// each read (ADR-0031): observing it sees only jumps, so a UI polls it or adds a periodic
    /// observer. Within an item it goes back only on a seek, so a saver may count deltas as listening.
    public var position: TimeInterval { readPosition() }
    /// Where `position` stands while the transport's clock does not say: a jump not yet heard, or nothing loaded.
    private var storedPosition: TimeInterval = 0
    /// Changes whenever `position` jumps rather than plays on: a seek, skip, load, item transition or
    /// repeat, as media3's `onPositionDiscontinuity`. It changes with the call, alongside the new
    /// `position`, so a reader never pairs it with the old one. Compare it; it may move more than once.
    public private(set) var discontinuityCount = 0
    /// Nil until the item's source has opened, and when the source does not know it.
    public private(set) var duration: TimeInterval?
    /// media3 `isCurrentMediaItemSeekable`: the source said so once it opened (ADR-0022).
    public var isSeekable: Bool { seekable == true }
    /// Neither seekable nor of known duration once opened (ADR-0022).
    public var isLive: Bool { seekable == false && duration == nil }
    /// media3 `getAudioFormat()`: the current item's decoded format, the one the processors run at
    /// for it. Nil until its audio is heard; a next item's replaces it when the join is heard, and a
    /// change within the item (`ItemSource.currentFormat`) when that is heard.
    public private(set) var audioFormat: PCMFormat?
    /// media3 `getTotalBufferedDuration()`: seconds of PCM written past what is heard, into the next
    /// item too. Not observed: it changes every pump, so poll it.
    public var bufferedAhead: TimeInterval { transport.bufferedAhead }
    /// The source's `isSeekable`, nil until it has opened.
    private var seekable: Bool?

    @ObservationIgnored public let events: AsyncStream<PlayerEvent<Item>>
    /// Each event as it is sent, before `events` yields it: a test sees it without awaiting the stream.
    @_spi(Testing) @ObservationIgnored public var onEvent: ((PlayerEvent<Item>) -> Void)?

    /// Awaited before a loaded item first plays: the item is prepared and paused meanwhile, and the
    /// transport starts when this returns. A pause, stop or load that replaces the item ends the wait
    /// and the item then starts only on the next `play()`. Resumes, seeks and gapless joins are not gated.
    @ObservationIgnored public var startGate: (@Sendable (Item) async -> Void)?

    /// Called synchronously when a gate in flight is cancelled, before its task resumes, so the reason
    /// is the one at cancel time even if a later `play()` is already queued. It must not re-enter the player synchronously.
    @ObservationIgnored public var startGateEnded: (@MainActor (StartGateEnd<Item>) -> Void)?

    private var intent = false {
        didSet {
            updateRebuffering()
            if !intent { endGate(.intentWithdrawn) }
        }
    }
    private var storedRate: Double = 1
    private var storedVolume: Float = 1

    @ObservationIgnored private let continuation: AsyncStream<PlayerEvent<Item>>.Continuation
    @ObservationIgnored private let makeSource: ItemSourceFactory<Item>
    @ObservationIgnored private let session: any AudioSessionControlling
    @ObservationIgnored private let inbox = TransportInbox()
    @ObservationIgnored private(set) var transport: Transport<Int>!
    @ObservationIgnored private var entries: [Entry] = [] {
        didSet { items = entries.map(\.item) }
    }
    @ObservationIgnored private var lastID = 0
    /// The entry id behind each key handed to the transport since the last `setCurrent`. Every load
    /// and arm takes a fresh key, so a repeat of the current entry is told from its own first audio.
    @ObservationIgnored private var keyedEntries: [Int: Int] = [:]
    @ObservationIgnored private var lastKey = 0
    @ObservationIgnored let keyedItems = KeyedItems<Item>()
    /// The current entry's key while the transport holds it; nil when stopped, or ended by an edit.
    @ObservationIgnored private var loadedKey: Int?
    @ObservationIgnored private var armedKey: Int?
    private var armedEntryID: Int? { armedKey.flatMap { keyedEntries[$0] } }
    @ObservationIgnored private var transportStatus = TransportStatus.paused
    /// The state while nothing is loaded: `.ended` once the current last item was removed (media3).
    @ObservationIgnored private var unloadedState = PlaybackState.idle
    /// `setCurrent` and `seek` calls the transport has not yet answered with `.sought` (media3's
    /// `pendingOperationAcks`); events meanwhile wait in `held` until each call says whether it
    /// replaced them.
    @ObservationIgnored private var unansweredCalls = 0
    @ObservationIgnored private var held: [TransportEvent<Int>] = []
    /// A seek within the current item whose audio has not been heard yet.
    @ObservationIgnored private var seekTarget: TimeInterval?
    /// The loaded item's audio has landed since the last jump, so `position` reads the transport.
    @ObservationIgnored private var followsTransport = false
    @ObservationIgnored private var lastRead: (discontinuity: Int, seconds: TimeInterval)?
    /// Where a load asked its item to start, until the item is heard: a source that cannot seek
    /// lands elsewhere, which is an adjustment but no `seekLanded`.
    @ObservationIgnored private var startTarget: TimeInterval?
    /// A load, seek or transition whose audio has not been heard playing; until then a wait is the
    /// join, not a rebuffer.
    @ObservationIgnored private var awaitingFirstAudio = false {
        didSet { updateRebuffering() }
    }
    @ObservationIgnored private var rebuffering = false
    /// The transport heard the end of the list; nothing is armed until a seek or load restarts it.
    @ObservationIgnored private var atEnd = false
    /// Paused by `pauseAtEndOfItem` at the end of the current item; `play()` moves on to the next.
    /// Every exit is a load or unload, so the transport's key may be stale meanwhile.
    @ObservationIgnored private var pausedAtEnd = false
    /// The next that failed before it was heard, reported when playback reaches it (media3).
    @ObservationIgnored private var failedNext: (entryID: Int, error: PlaybackError)?
    /// The session is ours until an interruption, a reset or our own deactivation; the transport
    /// plays only while it is.
    @ObservationIgnored private var sessionActive = false
    /// The activation awaiting its answer; a stop or interruption since makes the answer stale.
    @ObservationIgnored private var pendingActivation: Int?
    @ObservationIgnored private var lastActivation = 0
    /// The loaded item has not started yet, so its first play waits on `startGate`.
    @ObservationIgnored private var gatePending = false
    @ObservationIgnored private var gateTask: Task<Void, Never>?
    @ObservationIgnored private var gateItem: Item?

    public convenience init(
        makeSource: @escaping ItemSourceFactory<Item>,
        audioSession: AudioSessionConfiguration = .longFormAudio
    ) {
        self.init(makeSource: makeSource, session: SystemAudioSession(configuration: audioSession)) {
            Transport(onEvent: $0)
        }
    }

    @_spi(Testing) public init(
        makeSource: @escaping ItemSourceFactory<Item>,
        session: any AudioSessionControlling,
        makeTransport: (@escaping @Sendable (TransportEvent<Int>) -> Void) -> Transport<Int>
    ) {
        self.makeSource = makeSource
        self.session = session
        (events, continuation) = AsyncStream.makeStream()
        let inbox = inbox
        // Events arrive on the transport's queue; one drain on the main actor takes them in order.
        transport = makeTransport { [weak self] event in
            guard inbox.post(event) else { return }
            Task { @MainActor in self?.drainTransportEvents() }
        }
        session.configure()
        session.setEventHandler { [weak self] in self?.handleSession($0) }
    }

    deinit {
        continuation.finish()
    }

    nonisolated static func isPlaying(state: PlaybackState, playWhenReady: Bool, suppression: PlaybackSuppression) -> Bool {
        state == .ready && playWhenReady && suppression == .unsuppressed
    }

    // MARK: Items

    /// Replaces the list and plays `items[startIndex]` from `startPosition` once `playWhenReady`.
    public func setItems(_ items: [Item], startIndex: Int = 0, startPosition: TimeInterval = 0) {
        guard !items.isEmpty else { return removeAll() }
        precondition(items.indices.contains(startIndex), "startIndex out of range")
        entries = items.map(newEntry)
        currentIndex = startIndex
        load(startIndex, at: startPosition)
    }

    /// Keeps playing if `newItems[currentIndex]` is the item playing now; otherwise behaves as `setItems`.
    public func replaceItems(_ newItems: [Item], currentIndex index: Int) {
        guard !newItems.isEmpty else { return removeAll() }
        precondition(newItems.indices.contains(index), "currentIndex out of range")
        guard let current = currentIndex, entries[current].item == newItems[index] else {
            return setItems(newItems, startIndex: index)
        }
        let kept = entries[current]
        let armed = armedEntryID.flatMap { id in entries.first { $0.id == id } }
        entries = newItems.enumerated().map { offset, item in
            if offset == index { return kept }
            // The armed next keeps its id if it is still next, so the transport keeps its source.
            if offset == index + 1, let armed, armed.item == item { return armed }
            return newEntry(item)
        }
        currentIndex = index
        armNext()
    }

    public func insert(_ items: [Item], at index: Int) {
        precondition((0...entries.count).contains(index), "index out of range")
        guard !items.isEmpty else { return }
        guard let current = currentIndex else { return setItems(items) }
        entries.insert(contentsOf: items.map(newEntry), at: index)
        if index <= current { currentIndex = current + items.count }
        armNext()
    }

    /// Moves one item as `Array.remove(at: from)` then `insert(at: to)` would.
    public func move(from: Int, to: Int) {
        precondition(entries.indices.contains(from) && entries.indices.contains(to), "index out of range")
        guard from != to, let current = currentIndex else { return }
        entries.insert(entries.remove(at: from), at: to)
        if from == current {
            currentIndex = to
        } else if from < current, to >= current {
            currentIndex = current - 1
        } else if from > current, to <= current {
            currentIndex = current + 1
        }
        armNext()
    }

    /// Removing the current item plays the one that takes its index from 0, under `.all` the first
    /// if it was the last. With nothing to follow, or under `.one`, the player ends at that index, as
    /// media3 does; stopped, it stays idle until `play()`.
    public func remove(at index: Int) {
        precondition(entries.indices.contains(index), "index out of range")
        guard let current = currentIndex, entries.count > 1 else { return removeAll() }
        let previous = ref(current)
        entries.remove(at: index)
        if index < current {
            currentIndex = current - 1
        } else if index == current {
            let successor = index < entries.count ? index : 0
            currentIndex = successor
            movePosition(to: 0)
            forgetSource()
            // A failure that opened its source still holds a key, yet nothing plays to reach an end.
            let ends = loadedKey != nil && error == nil && (repeatMode == .one || (index == entries.count && repeatMode == .off))
            if ends { unload(as: .ended) }
            // Before the load, whose failure to make a source is reported after the transition.
            send(.itemTransition(from: previous, to: ref(successor), reason: .seek))
            if !ends, loadedKey != nil || error != nil { jump(to: successor, at: 0) }
        }
        armNext()
    }

    public func removeAll() {
        let previous = currentIndex.map(ref)
        entries = []
        currentIndex = nil
        error = nil
        unload(as: .idle)
        movePosition(to: 0)
        forgetSource()
        if previous != nil { send(.itemTransition(from: previous, to: nil, reason: .seek)) }
    }

    // MARK: Transport

    /// The app's intent. The app and the player's session rules change it; the transport never does.
    /// True with the session not yet active, the transport waits for the activation; if that throws,
    /// `error` is `.session` and the next `play()` tries again.
    public var playWhenReady: Bool {
        get { intent }
        set {
            intent = newValue
            guard newValue else {
                // An app pause outranks an interruption, so its end resumes nothing.
                suppression = .unsuppressed
                return transport.pause()
            }
            guard let current = currentIndex else { return }
            if pausedAtEnd {
                // media3 moves on from a pause at the end of an item when playback resumes; with
                // nothing left to follow it, as from an end.
                let next = following(current)
                if let next {
                    currentIndex = next
                    movePosition(to: 0)
                    forgetSource()
                    // Before the load, whose failure to make a source is reported after the transition.
                    send(.itemTransition(from: ref(current), to: ref(next), reason: next == current ? .repeat : .auto))
                }
                load(next ?? current, at: 0)
            } else if loadedKey == nil || error != nil {
                // media3 `prepare()`: after a stop or an error, from the position; at the end, from 0.
                load(current, at: state == .ended ? 0 : position)
            } else if state == .ended, let loadedKey {
                seekTransport(item: loadedKey, to: 0)
                movePosition(to: 0)
                armNext()
            }
            // A load that failed left nothing to play, so the session stays inactive.
            guard error == nil else { return }
            if sessionActive { startTransport() } else { activate() }
        }
    }

    public func play() { playWhenReady = true }

    public func pause() { playWhenReady = false }

    /// `.idle` with the items and position kept; `play()` prepares the current item again.
    public func stop() {
        unload(as: .idle)
    }

    public var repeatMode = RepeatMode.off {
        didSet { armNext() }
    }

    /// media3 `pauseAtEndOfMediaItems`: at the end of each item, sets `playWhenReady` false (sent as
    /// `playWhenReadyChanged(false, reason: .endOfItem)`) and stays on that item, `.ready` at its end;
    /// `play()` moves on to the next. At the end of the last it ends. Nothing is armed meanwhile.
    public var pauseAtEndOfItem = false {
        didSet { armNext() }
    }

    var hasNext: Bool { neighbour(1) != nil }
    var hasPrevious: Bool { neighbour(-1) != nil }

    public func skipToNext() {
        guard let next = neighbour(1) else { return }
        skip(to: next)
    }

    public func skipToPrevious() {
        guard let previous = neighbour(-1) else { return }
        skip(to: previous)
    }

    // A wrap onto the only item is still a transition, as media3's `isRepeatingCurrentItem` seek is.
    private func skip(to index: Int) {
        guard index == currentIndex else { return seek(to: 0, itemAt: index) }
        seek(to: 0)
        send(.itemTransition(from: ref(index), to: ref(index), reason: .seek))
    }

    // MARK: Position

    /// Clamped to `0...duration` when the duration is known. Refused once the item's source has said
    /// it cannot seek. A clamp or refusal is reported as `.seekAdjusted`, never dropped silently.
    public func seek(to position: TimeInterval) {
        guard let current = currentIndex, position.isFinite else { return }
        guard seekable != false else {
            return send(.seekAdjusted(ref(current), requested: position, position: self.position))
        }
        let target = min(max(position, 0), duration ?? .infinity)
        defer { if target != position { send(.seekAdjusted(ref(current), requested: position, position: target)) } }
        if let loadedKey, error == nil, !pausedAtEnd {
            seekTransport(item: loadedKey, to: target)
            movePosition(to: target)
            seekTarget = target
            armNext()
        } else if unloadedState == .ended || pausedAtEnd, error == nil {
            load(current, at: target)
            seekTarget = target
        } else {
            // Idle: `play()` prepares from here.
            movePosition(to: target)
        }
    }

    /// Stopped or failed, only moves where `play()` prepares from, as media3 stays idle until `prepare`.
    public func seek(to position: TimeInterval, itemAt index: Int) {
        precondition(entries.indices.contains(index), "index out of range")
        guard let current = currentIndex, index != current else { return seek(to: position) }
        let seconds = position.isFinite ? max(position, 0) : 0
        // Not `state`, which waits for the transport to answer a load.
        let idle = error != nil || (loadedKey == nil && unloadedState == .idle)
        currentIndex = index
        movePosition(to: seconds)
        forgetSource()
        // Before the load, whose failure to make a source is reported after the transition.
        send(.itemTransition(from: ref(current), to: ref(index), reason: .seek))
        if !idle { jump(to: index, at: seconds) }
    }

    /// Clamps to the current item; never moves to another. Adds to a seek not yet heard, so presses
    /// faster than a pump add up.
    public func seek(by delta: TimeInterval) {
        seek(to: (seekTarget ?? position) + delta)
    }

    // MARK: Rate, volume, processors

    /// Speed with pitch kept, clamped to 0.25...4. Pause is `playWhenReady`, never rate 0.
    public var rate: Double {
        get { storedRate }
        set {
            guard newValue.isFinite else { return }
            storedRate = min(max(newValue, 0.25), 4)
            transport.setRate(storedRate)
        }
    }

    /// Gain, clamped to 0...1 and applied at once; a fade is the app writing this from its own timer.
    public var volume: Float {
        get { storedVolume }
        set {
            guard newValue.isFinite else { return }
            storedVolume = min(max(newValue, 0), 1)
            transport.setVolume(storedVolume)
        }
    }

    /// Each processor's `flush` gets the `Item` whose frames follow. Re-feeds from the heard frame,
    /// so the change is heard at once, after a brief rebuffer.
    public func setProcessors(_ processors: [any AudioProcessor]) {
        transport.setProcessors(processors.map(keyedItems.keyed))
    }

    /// Call after changing a processor's own parameters (a gain, EQ bands) so they are heard at once,
    /// after a brief rebuffer, not after the audio already written. Fade through `volume` instead.
    public func processorsChanged() {
        transport.processorsChanged()
    }

    // MARK: Transport events

    /// Applies every transport event posted so far, in order. Tests call it after a pump.
    @_spi(Testing) public func drainTransportEvents() {
        for event in inbox.drain() {
            if case let .sought(_, _, applied) = event {
                unansweredCalls -= 1
                // An applied call restarted from a new place, so what was heard before it is moot; a
                // restart buffers, and reports a status after only if that changed.
                // An ignored seek changed nothing, so everything before it stands (a crossing above all).
                // A duration is state the transport sends once per item, so it survives the drop.
                if applied {
                    transportStatus = .buffering
                    held = held.filter { if case .durationChanged = $0 { true } else { false } }
                }
                if unansweredCalls == 0 {
                    let replay = held
                    held = []
                    replay.forEach(apply)
                    refreshState()
                }
                continue
            }
            // A failed armed next is dropped, and a recovery's pause stands, whatever was called since.
            let outlivesCalls = switch event {
            case let .failed(key?, _): key == armedKey
            case .recovered: true
            default: false
            }
            if unansweredCalls > 0, !outlivesCalls {
                held.append(event)
                continue
            }
            apply(event)
        }
    }

    // MARK: Audio session

    private func activate() {
        guard pendingActivation == nil else { return }
        lastActivation += 1
        let id = lastActivation
        pendingActivation = id
        session.activate { [weak self] failure in
            guard let self, pendingActivation == id else { return }
            pendingActivation = nil
            if let failure {
                // Refused during an interruption, the interruption still holds; its end tries again.
                guard suppression == .unsuppressed, intent else { return }
                error = PlaybackError(kind: .session, underlying: failure)
                return refreshState()
            }
            sessionActive = true
            suppression = .unsuppressed
            if intent, loadedKey != nil, error == nil { startTransport() }
        }
    }

    /// `transport.play()`, after `startGate` if the loaded item has not started yet.
    private func startTransport() {
        guard gatePending, let startGate, let item = currentItem, let key = loadedKey else {
            gatePending = false
            return transport.play()
        }
        guard gateTask == nil else { return }
        gateItem = item
        gateTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            await startGate(item)
            guard !Task.isCancelled, let self else { return }
            gateTask = nil
            gateItem = nil
            gatePending = false
            if intent, sessionActive, suppression == .unsuppressed, loadedKey == key, error == nil { transport.play() }
        }
    }

    /// Cancelled with the intent, a stop or a new load, so a finished gate never starts a stale item.
    private func endGate(_ reason: StartGateEndReason) {
        guard let gateTask else { return }
        gateTask.cancel()
        let item = gateItem
        self.gateTask = nil
        gateItem = nil
        gatePending = false
        if let item { startGateEnded?(StartGateEnd(item: item, reason: reason)) }
    }

    private func deactivate() {
        guard sessionActive || pendingActivation != nil else { return }
        sessionActive = false
        pendingActivation = nil
        session.deactivate()
    }

    private func handleSession(_ event: AudioSessionEvent) {
        switch event {
        case .interruptionBegan:
            // The system has deactivated the session, so the next play activates it again.
            sessionActive = false
            pendingActivation = nil
            // Stopped, ended or failed, nothing plays to suppress, so the end has nothing to resume or cancel.
            guard intent, loadedKey != nil, !atEnd, error == nil else { return }
            suppression = .interruption
            transport.pause()
        case let .interruptionEnded(shouldResume):
            // Only an interruption that paused us resumes: an app pause or a route loss cleared it.
            guard suppression == .interruption else { return }
            if shouldResume {
                // Over, so a refused activation is a session error for the app, not a held interruption.
                suppression = .unsuppressed
                return activate()
            }
            suppression = .unsuppressed
            intent = false
            send(.playWhenReadyChanged(false, reason: .interruptionEnded))
        case let .routeChanged(reason, previous, current):
            // media3 "becoming noisy": only losing a personal output pauses, never a profile switch.
            let lost = previous.contains { $0.isPersonal && !current.contains($0) }
            guard reason == .oldDeviceUnavailable, lost, intent else { return }
            pauseByPlayer(.routeLost)
        case .mediaServicesReset:
            // The session is gone, interruption and all. The transport rebuilds its output on its
            // own and reports `.recovered`, which lands the player paused.
            session.configure()
            sessionActive = false
            pendingActivation = nil
            suppression = .unsuppressed
        }
    }

    /// The transport rebuilt its output and restarted paused, so the intent follows it and nothing
    /// resumes. Its pause also covers a play it took before the player heard of the recovery.
    private func recoveredPaused() {
        guard loadedKey != nil else { return }
        intent = false
        suppression = .unsuppressed
        transport.pause()
        send(.recoveredPaused)
    }

    // MARK: Private

    private func apply(_ event: TransportEvent<Int>) {
        switch event {
        case let .landed(key, seconds):
            guard key == loadedKey, let current = currentIndex else { return }
            storedPosition = seconds
            followsTransport = true
            if let target = seekTarget ?? startTarget {
                if seekTarget != nil { send(.seekLanded(ref(current), position: seconds)) }
                seekTarget = nil
                startTarget = nil
                landed(at: seconds, seekingTo: target, index: current)
            }
            firstAudioIfPlaying()
        case let .durationChanged(key, duration, isSeekable):
            guard key == loadedKey else { return }
            self.duration = duration
            seekable = isSeekable
        case let .status(status):
            transportStatus = status
            if status == .ended, reachedEnd() { return }
            refreshState()
            firstAudioIfPlaying()
        case let .failed(key, underlying):
            failed(key, underlying)
        case let .crossed(key, format):
            crossed(into: key)
            if key == loadedKey, audioFormat != format { audioFormat = format }
            firstAudioIfPlaying()
        case let .formatChanged(key, format):
            if key == loadedKey, audioFormat != format { audioFormat = format }
        case .recovered:
            recoveredPaused()
        case .sought:
            break
        }
    }

    private func newEntry(_ item: Item) -> Entry {
        lastID += 1
        return Entry(id: lastID, item: item)
    }

    private func index(of id: Int) -> Int? {
        entries.firstIndex { $0.id == id }
    }

    /// Where a skip by `offset` goes: media3 wraps under `.all` and treats `.one` as `.off`.
    private func neighbour(_ offset: Int) -> Int? {
        guard let current = currentIndex else { return nil }
        let index = current + offset
        if entries.indices.contains(index) { return index }
        return repeatMode == .all ? (index + entries.count) % entries.count : nil
    }

    /// The item played when `index` ends.
    private func following(_ index: Int) -> Int? {
        switch repeatMode {
        case .one: index
        case .all: (index + 1) % entries.count
        case .off: index + 1 < entries.count ? index + 1 : nil
        }
    }

    /// Makes `index` current at `seconds`: a seek if the transport already holds it as the armed
    /// next, so its open source is kept, otherwise a fresh `setCurrent`.
    private func jump(to index: Int, at seconds: TimeInterval) {
        guard let armedKey, entries[index].id == armedEntryID, loadedKey != nil, error == nil else {
            return load(index, at: seconds)
        }
        // A gate in flight belongs to the item being left; the new current is gated afresh.
        let gated = gateTask != nil
        endGate(.superseded)
        seekTransport(item: armedKey, to: seconds)
        loadedKey = armedKey
        self.armedKey = nil
        seekTarget = nil
        startTarget = nil
        movePosition(to: seconds)
        forgetSource()
        if gated {
            gatePending = true
            if intent, suppression == .unsuppressed { sessionActive ? startTransport() : activate() }
        }
        armNext()
    }

    /// Every jump of `position`. A recovery restarts from what was heard, so it never jumps.
    private func movePosition(to seconds: TimeInterval) {
        storedPosition = seconds
        followsTransport = false
        discontinuityCount += 1
    }

    /// The transport's clock once the current item's audio is heard. Before the main actor learns of a
    /// crossing the transport already reads the next item, so the last read holds until it does.
    private func readPosition() -> TimeInterval {
        if followsTransport, let loadedKey, let heard = transport.position, heard.item == loadedKey {
            lastRead = (discontinuityCount, heard.seconds)
            return heard.seconds
        }
        if let lastRead, lastRead.discontinuity == discontinuityCount, followsTransport { return lastRead.seconds }
        return storedPosition
    }

    /// The first audio after a load, seek or crossing is heard once it has landed with the clock
    /// running, as media3's `onAudioPositionAdvancing`.
    private func firstAudioIfPlaying() {
        guard awaitingFirstAudio, followsTransport, transportStatus == .playing, let current = currentIndex else { return }
        awaitingFirstAudio = false
        send(.firstAudioRendered(ref(current), position: position))
    }

    /// A source that lands away from the target (a keyframe, a time-offset URL) moves `position`
    /// again, as media3's `DISCONTINUITY_REASON_SEEK_ADJUSTMENT`. Rounding to a frame moves it under
    /// a millisecond at any real sample rate, which is no adjustment.
    private func landed(at seconds: TimeInterval, seekingTo target: TimeInterval, index: Int) {
        guard abs(seconds - target) > 0.001 else { return }
        discontinuityCount += 1
        send(.seekAdjusted(ref(index), requested: target, position: seconds))
    }

    /// What a load, skip or edit leaves until the next item's source opens.
    private func forgetSource() {
        duration = nil
        seekable = nil
        audioFormat = nil
    }

    private func seekTransport(item key: Int, to seconds: TimeInterval) {
        atEnd = false
        pausedAtEnd = false
        awaitingFirstAudio = true
        unansweredCalls += 1
        transport.seek(item: key, toSeconds: seconds)
        refreshState()
    }

    /// A gapless join reached the speaker. It is usually into the armed next, but may be into one
    /// armed before an edit that decode had already passed, so the item is found by its key.
    private func crossed(into key: Int) {
        keyedItems.forget(below: key)
        // The first audio after a load or seek is the current item's own.
        guard key != loadedKey, let from = currentIndex, let entryID = keyedEntries[key] else { return }
        if pauseAtEndOfItem {
            // Decode passed into a next that pause at end could no longer clear. media3 flushes back
            // to the current item there (`setPauseAtEndOfWindowInternal`), so the player stays on it.
            transport.pause()
            return pauseAtEnd()
        }
        loadedKey = key
        if key == armedKey { armedKey = nil }
        awaitingFirstAudio = true
        seekTarget = nil
        startTarget = nil
        movePosition(to: 0)
        // The join is heard: the transport's clock is already in this item.
        followsTransport = true
        forgetSource()
        guard let index = index(of: entryID) else {
            // Removed since it was armed, so the current has ended: on to what the list armed after
            // it, else as at the end of the current (a failed next, pause at end, or the list's end).
            guard let next = armedEntryID.flatMap(index(of:)) else {
                if !reachedEnd() { unload(as: .ended) }
                return
            }
            currentIndex = next
            send(.itemTransition(from: ref(from), to: ref(next), reason: .auto))
            return jump(to: next, at: 0)
        }
        currentIndex = index
        send(.itemTransition(from: ref(from), to: ref(index), reason: index == from ? .repeat : .auto))
        armNext()
    }

    /// The transport heard everything set. Returns true if the state waits for the next item's load.
    private func reachedEnd() -> Bool {
        // A next armed since the transport ended plays on.
        guard let current = currentIndex, loadedKey != nil, armedKey == nil, error == nil else { return false }
        if let failedNext, let index = index(of: failedNext.entryID) {
            self.failedNext = nil
            currentIndex = index
            movePosition(to: 0)
            forgetSource()
            unload(as: .idle)
            send(.itemTransition(from: ref(current), to: ref(index), reason: index == current ? .repeat : .auto))
            reportFailure(at: index, failedNext.error)
            return true
        }
        guard pauseAtEndOfItem, following(current) != nil else {
            if pauseAtEndOfItem { pauseByPlayer(.endOfItem) }
            atEnd = true
            nothingToPlay(.ended)
            return false
        }
        pauseAtEnd()
        return true
    }

    /// Pauses on the current item at its end, `.ready`, as media3 `pauseAtEndOfMediaItems` does.
    private func pauseAtEnd() {
        atEnd = true
        pausedAtEnd = true
        storedPosition = duration ?? position
        followsTransport = false
        refreshState()
        pauseByPlayer(.endOfItem)
    }

    private func pauseByPlayer(_ reason: PlayWhenReadyChangeReason) {
        intent = false
        suppression = .unsuppressed
        transport.pause()
        send(.playWhenReadyChanged(false, reason: reason))
    }

    /// `setCurrent` of the entry at `index`, then the next armed after it.
    func load(_ index: Int, at seconds: TimeInterval) {
        let entry = entries[index]
        awaitingFirstAudio = true
        movePosition(to: max(seconds, 0))
        forgetSource()
        armedKey = nil
        seekTarget = nil
        startTarget = position
        let source: any ItemSource
        do {
            source = try makeSource(entry.item)
        } catch {
            endGate(.superseded)
            unload(as: .idle)
            return reportFailure(at: index, PlaybackError(kind: .source, underlying: error))
        }
        let key = newKey(for: entry, replacing: true)
        atEnd = false
        pausedAtEnd = false
        failedNext = nil
        unansweredCalls += 1
        transport.setCurrent(item: key, source: source, startSeconds: position)
        loadedKey = key
        error = nil
        refreshState()
        // During an interruption a seek or skip is applied paused. Otherwise the intent takes the
        // session it lacks, as after a play with nothing to play.
        endGate(.superseded)
        gatePending = true
        if intent, suppression == .unsuppressed { sessionActive ? startTransport() : activate() }
        armNext()
    }

    /// Stops the transport and forgets what it held, keeping the list and position.
    private func unload(as state: PlaybackState) {
        storedPosition = position
        followsTransport = false
        endGate(.intentWithdrawn)
        transport.stop()
        keyedEntries = [:]
        keyedItems.forget(below: lastKey + 1)
        pausedAtEnd = false
        loadedKey = nil
        armedKey = nil
        seekTarget = nil
        startTarget = nil
        unloadedState = state
        nothingToPlay(state)
        refreshState()
    }

    /// Nothing playable is left, so an interruption has nothing to resume and its end activates
    /// nothing. Idle also gives the session up: media3 abandons focus in `STATE_IDLE` but holds it in
    /// `STATE_ENDED`, where `play()` restarts at once.
    private func nothingToPlay(_ state: PlaybackState) {
        suppression = .unsuppressed
        if state == .idle { deactivate() }
    }

    /// A transport key for `entryID`; `replacing` forgets the keys of everything a `setCurrent` drops.
    private func newKey(for entry: Entry, replacing: Bool = false) -> Int {
        lastKey += 1
        if replacing { keyedEntries = [:] }
        keyedEntries[lastKey] = entry.id
        keyedItems.record(entry.item, for: lastKey)
        return lastKey
    }

    /// Arms what follows the current, if it is not armed already. Nothing is armed at the end of
    /// the list, so an item added there waits for a seek, as in media3.
    private func armNext() {
        guard let current = currentIndex, loadedKey != nil, error == nil, !atEnd else { return }
        let next = pauseAtEndOfItem ? nil : following(current).map { entries[$0] }
        // A failed next stays unarmed while it is still the next; the end of the current reports it.
        if let failedNext, next?.id == failedNext.entryID { return }
        failedNext = nil
        guard next?.id != armedEntryID else { return }
        guard let next else {
            transport.clearNext()
            armedKey = nil
            return
        }
        do {
            let source = try makeSource(next.item)
            let key = newKey(for: next)
            transport.setNext(item: key, source: source)
            armedKey = key
        } catch {
            if armedKey != nil { transport.clearNext() }
            armedKey = nil
            failedNext = (next.id, PlaybackError(kind: .source, underlying: error))
        }
    }

    private func failed(_ key: Int?, _ underlying: any Error) {
        // A source or processor failure names its item; an output failure (nil) stops the current.
        if let key, key == armedKey, let entryID = keyedEntries[key] {
            // The transport dropped it and plays the current on.
            armedKey = nil
            failedNext = (entryID, PlaybackError(kind: .source, underlying: underlying))
            return
        }
        guard key == nil || key == loadedKey, let current = currentIndex else { return }
        reportFailure(at: current, PlaybackError(kind: key == nil ? .output : .source, underlying: underlying))
    }

    /// Failed is idle, as stopped is: the session goes (media3 abandons focus), and an interruption
    /// has nothing left to resume.
    private func reportFailure(at index: Int, _ error: PlaybackError) {
        self.error = error
        endGate(.superseded)
        nothingToPlay(.idle)
        refreshState()
        send(.itemFailed(ref(index), error: error))
    }

    private func refreshState() {
        state = if currentIndex == nil || error != nil {
            .idle
        } else if pausedAtEnd {
            .ready
        } else if loadedKey == nil {
            unloadedState
        } else if unansweredCalls > 0 {
            // media3 masks a load or seek as STATE_BUFFERING until it is acknowledged, so the state
            // never describes where playback was before the call.
            .buffering
        } else {
            switch transportStatus {
            case .paused, .playing: .ready
            case .buffering: .buffering
            case .ended: .ended
            }
        }
    }

    /// Called whenever an input changes; sends only on a change, so each start has one end.
    private func updateRebuffering() {
        let index = currentIndex
        let now = index != nil && state == .buffering && intent && suppression == .unsuppressed && !awaitingFirstAudio
        guard now != rebuffering else { return }
        rebuffering = now
        guard now, let index else { return send(.bufferingEnded) }
        send(.bufferingStarted(ref(index), position: position))
    }

    private func ref(_ index: Int) -> PlayerEvent<Item>.ItemRef {
        PlayerEvent.ItemRef(index: index, item: entries[index].item)
    }

    private func send(_ event: PlayerEvent<Item>) {
        onEvent?(event)
        continuation.yield(event)
    }
}

/// Transport events waiting for the main actor. `post` says whether the inbox was empty, so one
/// drain is scheduled per batch.
private final class TransportInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TransportEvent<Int>] = []

    func post(_ event: TransportEvent<Int>) -> Bool {
        lock.withLock {
            events.append(event)
            return events.count == 1
        }
    }

    func drain() -> [TransportEvent<Int>] {
        lock.withLock {
            defer { events = [] }
            return events
        }
    }
}
