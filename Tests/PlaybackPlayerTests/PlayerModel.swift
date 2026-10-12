import Foundation
@_spi(Testing) @testable import PlaybackPlayer

/// A reference for `Player`'s list, index, position and state with media3 `SimpleBasePlayer`
/// semantics, stepped in whole quarter seconds of heard audio. It knows nothing of transports,
/// decode lookahead or arming: the next item is whatever follows when the current one ends.
struct PlayerModel {
    struct Snapshot: Equatable, CustomStringConvertible {
        var items: [String]
        var currentIndex: Int?
        var state: PlaybackState
        var playWhenReady: Bool
        var position: TimeInterval
        var failed: Bool
        var hasNext: Bool
        var hasPrevious: Bool

        var description: String {
            "items \(items) current \(currentIndex.map(String.init) ?? "nil") \(state) "
                + "playWhenReady \(playWhenReady) position \(position) failed \(failed) "
                + "hasNext \(hasNext) hasPrevious \(hasPrevious)"
        }
    }

    enum Event: Equatable, CustomStringConvertible {
        case transition(from: Int?, to: Int?, reason: TransitionReason)
        case failed(index: Int)
        case pausedAtEndOfItem

        var description: String {
            switch self {
            case let .transition(from, to, reason):
                "transition(\(from.map(String.init) ?? "nil")->\(to.map(String.init) ?? "nil"), \(reason))"
            case let .failed(index): "failed(\(index))"
            case .pausedAtEndOfItem: "playWhenReadyChanged(false, .endOfItem)"
            }
        }
    }

    /// Seconds per item; an item missing here cannot be played (its source fails).
    let lengths: [String: TimeInterval]

    private(set) var items: [String] = []
    /// One identity per entry, parallel to `items`, since a list may hold the same item twice.
    private var ids: [Int] = []
    private var lastID = 0
    private(set) var currentIndex: Int?
    private(set) var position: TimeInterval = 0
    private(set) var playWhenReady = false
    var repeatMode = RepeatMode.off
    var pauseAtEndOfItem = false
    private(set) var events: [Event] = []
    /// Counts loads and item transitions, each a fresh start of the current item's playback.
    private(set) var playbacks = 0

    /// Nothing prepared: never loaded, stopped, failed or emptied.
    private var prepared = false
    private var failed = false
    private var ended = false
    private var pausedAtEnd = false
    /// The current item's duration is known once a load of it succeeded, so seeks clamp to it.
    private var durationKnown = false

    init(lengths: [String: TimeInterval]) {
        self.lengths = lengths
    }

    var snapshot: Snapshot {
        Snapshot(
            items: items,
            currentIndex: currentIndex,
            state: state,
            playWhenReady: playWhenReady,
            position: position,
            failed: failed,
            hasNext: neighbour(1) != nil,
            hasPrevious: neighbour(-1) != nil
        )
    }

    var state: PlaybackState {
        if currentIndex == nil || failed { return .idle }
        if pausedAtEnd { return .ready }
        if ended { return .ended }
        return prepared ? .ready : .idle
    }

    /// What plays when the current item ends, and how long until it does.
    var upNext: (entry: Int?, index: Int?, remaining: TimeInterval)? {
        guard let current = currentIndex, !failed else { return nil }
        let next = pauseAtEndOfItem ? nil : following(current)
        return (next.map { ids[$0] }, next, length(of: current) - position)
    }

    private mutating func newIDs(_ count: Int) -> [Int] {
        defer { lastID += count }
        return (lastID ..< lastID + count).map { $0 }
    }

    private var isPlaying: Bool {
        state == .ready && playWhenReady && !pausedAtEnd
    }

    mutating func takeEvents() -> [Event] {
        defer { events = [] }
        return events
    }

    // MARK: Items

    mutating func setItems(_ newItems: [String], startIndex: Int, startPosition: TimeInterval) {
        guard !newItems.isEmpty else { return removeAll() }
        items = newItems
        ids = newIDs(newItems.count)
        currentIndex = startIndex
        load(startIndex, at: startPosition)
    }

    mutating func insert(_ newItems: [String], at index: Int) {
        guard !newItems.isEmpty else { return }
        guard let current = currentIndex else { return setItems(newItems, startIndex: 0, startPosition: 0) }
        items.insert(contentsOf: newItems, at: index)
        ids.insert(contentsOf: newIDs(newItems.count), at: index)
        if index <= current { currentIndex = current + newItems.count }
    }

    mutating func move(from: Int, to: Int) {
        guard from != to, let current = currentIndex else { return }
        items.insert(items.remove(at: from), at: to)
        ids.insert(ids.remove(at: from), at: to)
        if from == current {
            currentIndex = to
        } else if from < current, to >= current {
            currentIndex = current - 1
        } else if from > current, to <= current {
            currentIndex = current + 1
        }
    }

    /// media3 `SimpleBasePlayer.handleRemoveMediaItems`: the item taking the removed one's place
    /// becomes current at 0; with none to follow, or under `.one`, the player ends there.
    mutating func remove(at index: Int) {
        guard let current = currentIndex, items.count > 1 else { return removeAll() }
        items.remove(at: index)
        ids.remove(at: index)
        if index < current {
            currentIndex = current - 1
        } else if index == current {
            let successor = index < items.count ? index : 0
            currentIndex = successor
            position = 0
            durationKnown = false
            let wasLoaded = prepared && !failed
            let ends = wasLoaded && (repeatMode == .one || (index == items.count && repeatMode == .off))
            events.append(.transition(from: current, to: successor, reason: .seek))
            if ends {
                prepared = false
                ended = true
                pausedAtEnd = false
            } else if wasLoaded || failed {
                load(successor, at: 0)
            }
        }
    }

    mutating func removeAll() {
        let previous = currentIndex
        items = []
        ids = []
        currentIndex = nil
        failed = false
        prepared = false
        ended = false
        pausedAtEnd = false
        position = 0
        durationKnown = false
        if previous != nil { events.append(.transition(from: previous, to: nil, reason: .seek)) }
    }

    // MARK: Transport

    mutating func play() {
        playWhenReady = true
        guard let current = currentIndex else { return }
        if pausedAtEnd {
            let next = following(current)
            if let next {
                currentIndex = next
                events.append(.transition(from: current, to: next, reason: next == current ? .repeat : .auto))
            }
            load(next ?? current, at: 0)
        } else if !prepared || failed {
            load(current, at: ended ? 0 : position)
        } else if ended {
            ended = false
            position = 0
        }
    }

    mutating func pause() {
        playWhenReady = false
    }

    mutating func stop() {
        prepared = false
        ended = false
        pausedAtEnd = false
    }

    // MARK: Position

    mutating func seek(to target: TimeInterval) {
        guard currentIndex != nil else { return }
        let clamped = min(max(target, 0), durationKnown ? length(of: currentIndex!) : .infinity)
        if prepared, !failed, !pausedAtEnd, !ended {
            position = clamped
        } else if (ended || pausedAtEnd), !failed {
            load(currentIndex!, at: clamped)
        } else {
            position = clamped
        }
    }

    mutating func seek(to target: TimeInterval, itemAt index: Int) {
        guard let current = currentIndex, index != current else { return seek(to: target) }
        let seconds = max(target, 0)
        let idle = failed || (!prepared && !ended)
        currentIndex = index
        position = seconds
        durationKnown = false
        events.append(.transition(from: current, to: index, reason: .seek))
        if !idle { load(index, at: seconds) }
    }

    mutating func skipToNext() {
        guard let next = neighbour(1) else { return }
        skip(to: next)
    }

    mutating func skipToPrevious() {
        guard let previous = neighbour(-1) else { return }
        skip(to: previous)
    }

    private mutating func skip(to index: Int) {
        guard index == currentIndex else { return seek(to: 0, itemAt: index) }
        seek(to: 0)
        events.append(.transition(from: index, to: index, reason: .seek))
    }

    // MARK: Clock

    /// A quarter second of output clock.
    mutating func tick() {
        guard isPlaying, let current = currentIndex else { return }
        position += 0.25
        let length = length(of: current)
        guard position >= length else { return }
        reachEnd(of: current, overflow: position - length)
    }

    private mutating func reachEnd(of current: Int, overflow: TimeInterval) {
        let length = length(of: current)
        if pauseAtEndOfItem {
            position = length
            playWhenReady = false
            events.append(.pausedAtEndOfItem)
            if following(current) != nil { pausedAtEnd = true } else { ended = true }
            return
        }
        guard let next = following(current) else {
            position = length
            ended = true
            return
        }
        currentIndex = next
        playbacks += 1
        events.append(.transition(from: current, to: next, reason: next == current ? .repeat : .auto))
        if lengths[items[next]] == nil {
            position = 0
            durationKnown = false
            prepared = false
            fail(at: next)
        } else {
            position = overflow
        }
    }

    // MARK: Private

    private func length(of index: Int) -> TimeInterval {
        lengths[items[index]] ?? 0
    }

    private func neighbour(_ offset: Int) -> Int? {
        guard let current = currentIndex else { return nil }
        let index = current + offset
        if items.indices.contains(index) { return index }
        return repeatMode == .all ? (index + items.count) % items.count : nil
    }

    private func following(_ index: Int) -> Int? {
        switch repeatMode {
        case .one: index
        case .all: (index + 1) % items.count
        case .off: index + 1 < items.count ? index + 1 : nil
        }
    }

    private mutating func load(_ index: Int, at seconds: TimeInterval) {
        position = max(seconds, 0)
        playbacks += 1
        ended = false
        pausedAtEnd = false
        guard lengths[items[index]] != nil else {
            prepared = false
            durationKnown = false
            return fail(at: index)
        }
        prepared = true
        failed = false
        durationKnown = true
        // media3 re-prepares at the kept position, so a load there plays straight into the end.
        if position >= length(of: index), playWhenReady { reachEnd(of: index, overflow: 0) }
    }

    private mutating func fail(at index: Int) {
        failed = true
        events.append(.failed(index: index))
    }
}
