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

    public private(set) var state = PlaybackState.idle
    public private(set) var suppression = PlaybackSuppression.none
    public var isPlaying: Bool { Self.isPlaying(state: state, playWhenReady: playWhenReady, suppression: suppression) }
    public private(set) var error: PlaybackError?

    /// What is heard, in seconds of the current item's media time, written on every pump while it
    /// changes. Within an item it goes back only on a seek, so a saver may count deltas as listening.
    public private(set) var position: TimeInterval = 0
    /// Nil until the item's source has opened, and for a live stream.
    public private(set) var duration: TimeInterval?
    public private(set) var isLive = false

    @ObservationIgnored public let events: AsyncStream<PlayerEvent<Item>>

    private var intent = false
    private var storedRate: Double = 1
    private var storedVolume: Float = 1

    @ObservationIgnored private let continuation: AsyncStream<PlayerEvent<Item>>.Continuation
    @ObservationIgnored private let makeSource: ItemSourceFactory<Item>
    @ObservationIgnored private let inbox = TransportInbox()
    @ObservationIgnored private var transport: Transport<Int>!
    @ObservationIgnored private var entries: [Entry] = [] {
        didSet { items = entries.map(\.item) }
    }
    @ObservationIgnored private var lastID = 0
    /// The current entry's id while the transport holds it; nil when stopped, or ended by an edit.
    @ObservationIgnored private var loadedID: Int?
    @ObservationIgnored private var armedID: Int?
    @ObservationIgnored private var transportStatus = TransportStatus.paused
    /// The state while nothing is loaded: `.ended` once the current last item was removed (media3).
    @ObservationIgnored private var unloadedState = PlaybackState.idle
    /// `setCurrent` and `seek` calls the transport has not yet answered with `.sought`; events before
    /// the last answer describe what those calls replaced (media3's `pendingOperationAcks`).
    @ObservationIgnored private var unansweredCalls = 0
    /// A seek within the current item whose audio has not been heard yet.
    @ObservationIgnored private var seekTarget: TimeInterval?

    public convenience init(
        makeSource: @escaping ItemSourceFactory<Item>,
        timePitchAlgorithm: AVAudioTimePitchAlgorithm = .timeDomain
    ) {
        self.init(makeSource: makeSource) { Transport(timePitchAlgorithm: timePitchAlgorithm, onEvent: $0) }
    }

    init(
        makeSource: @escaping ItemSourceFactory<Item>,
        makeTransport: (@escaping @Sendable (TransportEvent<Int>) -> Void) -> Transport<Int>
    ) {
        self.makeSource = makeSource
        (events, continuation) = AsyncStream.makeStream()
        let inbox = inbox
        // Events arrive on the transport's queue; one drain on the main actor takes them in order.
        transport = makeTransport { [weak self] event in
            guard inbox.post(event) else { return }
            Task { @MainActor in self?.drainTransportEvents() }
        }
    }

    deinit {
        continuation.finish()
    }

    nonisolated static func isPlaying(state: PlaybackState, playWhenReady: Bool, suppression: PlaybackSuppression) -> Bool {
        state == .ready && playWhenReady && suppression == .none
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
        let armed = armedID.flatMap { id in entries.first { $0.id == id } }
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

    /// Removing the current item plays the one that takes its index from 0; if it was the last, the
    /// player ends at the first item, as media3 does.
    public func remove(at index: Int) {
        precondition(entries.indices.contains(index), "index out of range")
        guard let current = currentIndex, entries.count > 1 else { return removeAll() }
        entries.remove(at: index)
        if index < current {
            currentIndex = current - 1
        } else if index == current {
            if index < entries.count {
                currentIndex = index
                if loadedID != nil || error != nil { jump(to: index, at: 0) }
            } else {
                currentIndex = 0
                unload(as: .ended)
            }
            position = 0
            duration = nil
            send(.itemTransition(from: current, to: currentIndex, reason: .seek))
        }
        armNext()
    }

    public func removeAll() {
        let previous = currentIndex
        entries = []
        currentIndex = nil
        error = nil
        unload(as: .idle)
        position = 0
        duration = nil
        isLive = false
        if previous != nil { send(.itemTransition(from: previous, to: nil, reason: .seek)) }
    }

    // MARK: Transport

    /// The app's intent. Only the app (or, later, a session event) changes it; the transport never does.
    public var playWhenReady: Bool {
        get { intent }
        set {
            intent = newValue
            guard newValue else { return transport.pause() }
            guard let current = currentIndex else { return }
            if loadedID == nil || error != nil {
                // media3 `prepare()`: after a stop or an error, from the position; at the end, from 0.
                load(current, at: state == .ended ? 0 : position)
            } else if state == .ended, let loadedID {
                seekTransport(item: loadedID, to: 0)
            }
            transport.play()
        }
    }

    public func play() { playWhenReady = true }

    public func pause() { playWhenReady = false }

    /// `.idle` with the items and position kept; `play()` prepares the current item again.
    public func stop() {
        unload(as: .idle)
    }

    public var hasNext: Bool { currentIndex.map { $0 + 1 < entries.count } ?? false }
    public var hasPrevious: Bool { currentIndex.map { $0 > 0 } ?? false }

    public func skipToNext() {
        guard hasNext, let current = currentIndex else { return }
        seek(to: 0, itemAt: current + 1)
    }

    public func skipToPrevious() {
        guard hasPrevious, let current = currentIndex else { return }
        seek(to: 0, itemAt: current - 1)
    }

    // MARK: Position

    /// Clamped to `0...duration` when the duration is known; ignored for a live item.
    public func seek(to position: TimeInterval) {
        guard let current = currentIndex, !isLive, position.isFinite else { return }
        let target = min(max(position, 0), duration ?? .infinity)
        if let loadedID, error == nil {
            seekTransport(item: loadedID, to: target)
            self.position = target
            seekTarget = target
        } else if unloadedState == .ended, error == nil {
            load(current, at: target)
            seekTarget = target
        } else {
            // Idle: `play()` prepares from here.
            self.position = target
        }
    }

    /// Stopped or failed, only moves where `play()` prepares from, as media3 stays idle until `prepare`.
    public func seek(to position: TimeInterval, itemAt index: Int) {
        precondition(entries.indices.contains(index), "index out of range")
        guard let current = currentIndex, index != current else { return seek(to: position) }
        let seconds = position.isFinite ? max(position, 0) : 0
        currentIndex = index
        if state == .idle {
            self.position = seconds
            duration = nil
            isLive = false
        } else {
            jump(to: index, at: seconds)
        }
        send(.itemTransition(from: current, to: index, reason: .seek))
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

    public func setProcessors(_ processors: [any AudioProcessor]) {
        transport.setProcessors(processors)
    }

    // MARK: Transport events

    /// Applies every transport event posted so far, in order. Tests call it after a pump.
    func drainTransportEvents() {
        for event in inbox.drain() {
            if case .sought = event {
                unansweredCalls -= 1
                continue
            }
            // A failed armed next is dropped by the transport whatever was called since.
            if unansweredCalls > 0 {
                guard case let .failed(id, _) = event, id != nil, id == armedID else { continue }
            }
            switch event {
            case let .position(id, seconds, duration):
                guard id == loadedID, let current = currentIndex else { continue }
                position = seconds
                self.duration = duration
                // The source has opened by the time audio is reported, so no duration means live.
                isLive = duration == nil
                if seekTarget != nil {
                    seekTarget = nil
                    send(.seekLanded(index: current, position: seconds))
                }
            case let .status(status):
                transportStatus = status
                refreshState()
            case let .failed(id, underlying):
                failed(id, underlying)
            case let .crossed(id):
                crossed(into: id)
            case .sought:
                break
            }
        }
    }

    // MARK: Private

    private func newEntry(_ item: Item) -> Entry {
        lastID += 1
        return Entry(id: lastID, item: item)
    }

    private func index(of id: Int) -> Int? {
        entries.firstIndex { $0.id == id }
    }

    /// Makes `index` current at `seconds`: a seek if the transport already holds it as the armed
    /// next, so its open source is kept, otherwise a fresh `setCurrent`.
    private func jump(to index: Int, at seconds: TimeInterval) {
        let entry = entries[index]
        guard entry.id == armedID, loadedID != nil, error == nil else { return load(index, at: seconds) }
        seekTransport(item: entry.id, to: seconds)
        loadedID = entry.id
        armedID = nil
        seekTarget = nil
        position = seconds
        duration = nil
        isLive = false
        armNext()
    }

    private func seekTransport(item id: Int, to seconds: TimeInterval) {
        unansweredCalls += 1
        transport.seek(item: id, toSeconds: seconds)
        expectRestartStatus()
    }

    /// A restart reports its status only if it changed, and the statuses before it are dropped.
    private func expectRestartStatus() {
        transportStatus = intent ? .buffering : .paused
        refreshState()
    }

    /// The gapless join into the armed next reached the speaker; any other crossing is the first
    /// audio of an item already current.
    private func crossed(into id: Int) {
        guard id == armedID, let from = currentIndex, let index = index(of: id) else { return }
        currentIndex = index
        loadedID = id
        armedID = nil
        seekTarget = nil
        position = 0
        duration = nil
        isLive = false
        send(.itemTransition(from: from, to: index, reason: .auto))
        armNext()
    }

    /// `setCurrent` of the entry at `index`, then the next armed after it.
    private func load(_ index: Int, at seconds: TimeInterval) {
        let entry = entries[index]
        position = max(seconds, 0)
        duration = nil
        isLive = false
        armedID = nil
        seekTarget = nil
        let source: any ItemSource
        do {
            source = try makeSource(entry.item)
        } catch {
            unload(as: .idle)
            return reportFailure(at: index, PlaybackError(kind: .source, underlying: error))
        }
        unansweredCalls += 1
        transport.setCurrent(item: entry.id, source: source, startSeconds: position)
        loadedID = entry.id
        error = nil
        if intent { transport.play() }
        expectRestartStatus()
        armNext()
    }

    /// Stops the transport and forgets what it held, keeping the list and position.
    private func unload(as state: PlaybackState) {
        transport.stop()
        loadedID = nil
        armedID = nil
        seekTarget = nil
        unloadedState = state
        refreshState()
    }

    /// Arms the list's next after the current, if it is not armed already.
    private func armNext() {
        guard let current = currentIndex, loadedID != nil, error == nil else { return }
        let next = current + 1 < entries.count ? entries[current + 1] : nil
        guard next?.id != armedID else { return }
        guard let next else {
            transport.clearNext()
            armedID = nil
            return
        }
        do {
            transport.setNext(item: next.id, source: try makeSource(next.item))
            armedID = next.id
        } catch {
            if armedID != nil { transport.clearNext() }
            armedID = nil
            send(.itemFailed(index: current + 1, error: PlaybackError(kind: .source, underlying: error)))
        }
    }

    private func failed(_ id: Int?, _ underlying: any Error) {
        // A source or processor failure names its item; an output failure (nil) stops the current.
        if let id, id == armedID {
            armedID = nil
            if let index = index(of: id) {
                send(.itemFailed(index: index, error: PlaybackError(kind: .source, underlying: underlying)))
            }
            return
        }
        guard id == nil || id == loadedID, let current = currentIndex else { return }
        reportFailure(at: current, PlaybackError(kind: id == nil ? .output : .source, underlying: underlying))
    }

    private func reportFailure(at index: Int, _ error: PlaybackError) {
        self.error = error
        refreshState()
        send(.itemFailed(index: index, error: error))
    }

    private func refreshState() {
        state = if currentIndex == nil || error != nil {
            .idle
        } else if loadedID == nil {
            unloadedState
        } else {
            switch transportStatus {
            case .paused, .playing: .ready
            case .buffering: .buffering
            case .ended: .ended
            }
        }
    }

    private func send(_ event: PlayerEvent<Item>) {
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
