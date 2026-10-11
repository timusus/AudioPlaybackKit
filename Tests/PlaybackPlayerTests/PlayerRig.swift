import Foundation
import PlaybackRender
import PlaybackRenderTestSupport
@testable import PlaybackPlayer

/// A `Player<String>` on the fake output, manual pump and manual decode, with transport events
/// delivered by hand so every step is chosen, not raced.
@MainActor
final class PlayerRig {
    struct Transition: Equatable {
        var from: Int?
        var to: Int?
        var reason: TransitionReason
    }

    let output = FakeAudioOutput()
    let timer = ManualPumpTimer()
    let executor = ManualExecutor()
    let factory = FakeItemFactory()
    let session = FakeAudioSession()
    private(set) var player: Player<String>!
    private let events: AsyncStream<PlayerEvent<String>>
    private let gate = EventGate()

    init() {
        let (output, timer, executor, factory, gate) = (output, timer, executor, factory, gate)
        player = Player(makeSource: { try factory.make($0) }, session: session) { onEvent in
            gate.forward = onEvent
            return Transport(output: output, timer: timer, executor: executor) { gate.send($0) }
        }
        events = player.events
    }

    /// Runs `body` and returns the transport events it caused, kept from the player as if still on
    /// their way to the main actor; `deliver` hands them over.
    func inFlight(_ body: () -> Void) -> [TransportEvent<Int>] {
        gate.holding = true
        body()
        timer.sync()
        return gate.release()
    }

    func deliver(_ events: [TransportEvent<Int>]) {
        events.forEach(gate.send)
        player.drainTransportEvents()
    }

    /// Runs every transport call made so far and delivers its events.
    func settle() {
        timer.sync()
        player.drainTransportEvents()
    }

    /// One pump: decode jobs, then the feeder's tick, then the events it sent.
    func pump() {
        timer.sync()
        executor.runUntilIdle()
        timer.fire()
        player.drainTransportEvents()
    }

    /// Pumps every quarter second of output clock for `seconds`, then once more.
    func run(for seconds: TimeInterval) {
        for _ in 0..<Int(seconds * 4) {
            pump()
            output.advance(by: 0.25)
        }
        pump()
    }

    /// The first sample written after the first `skipping` writes: the frame decode landed on.
    func firstSampleWritten(skipping: Int) -> Float? {
        output.enqueues.dropFirst(skipping).first?.samples.first
    }

    /// Drops the player, which finishes its event stream, and returns everything it sent.
    func finish() async -> [PlayerEvent<String>] {
        player = nil
        var all: [PlayerEvent<String>] = []
        for await event in events { all.append(event) }
        return all
    }

    enum Kind: Equatable {
        case itemTransition, itemFailed, seekLanded, recoveredPaused, playWhenReadyChanged
    }

    /// Each event's case, in the order sent.
    static func kinds(_ events: [PlayerEvent<String>]) -> [Kind] {
        events.map {
            switch $0 {
            case .itemTransition: .itemTransition
            case .itemFailed: .itemFailed
            case .seekLanded: .seekLanded
            case .recoveredPaused: .recoveredPaused
            case .playWhenReadyChanged: .playWhenReadyChanged
            }
        }
    }

    static func transitions(_ events: [PlayerEvent<String>]) -> [Transition] {
        events.compactMap {
            guard case let .itemTransition(from, to, reason) = $0 else { return nil }
            return Transition(from: from, to: to, reason: reason)
        }
    }

    static func failedIndices(_ events: [PlayerEvent<String>]) -> [Int] {
        events.compactMap {
            guard case let .itemFailed(index, _) = $0 else { return nil }
            return index
        }
    }

    static func seeksLanded(_ events: [PlayerEvent<String>]) -> [Landing] {
        events.compactMap {
            guard case let .seekLanded(index, position) = $0 else { return nil }
            return Landing(index: index, position: position)
        }
    }

    static func playWhenReadyChanges(_ events: [PlayerEvent<String>]) -> [PlayWhenReadyChange] {
        events.compactMap {
            guard case let .playWhenReadyChanged(value, reason) = $0 else { return nil }
            return PlayWhenReadyChange(value: value, reason: reason)
        }
    }

    struct PlayWhenReadyChange: Equatable {
        var value: Bool
        var reason: PlayWhenReadyChangeReason
    }

    struct Landing: Equatable {
        var index: Int
        var position: TimeInterval
    }
}

/// Passes transport events to the player, or holds them while `holding`.
private final class EventGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [TransportEvent<Int>] = []
    private var _holding = false
    private var _forward: (@Sendable (TransportEvent<Int>) -> Void)?

    var holding: Bool {
        get { lock.withLock { _holding } }
        set { lock.withLock { _holding = newValue } }
    }

    var forward: (@Sendable (TransportEvent<Int>) -> Void)? {
        get { lock.withLock { _forward } }
        set { lock.withLock { _forward = newValue } }
    }

    func send(_ event: TransportEvent<Int>) {
        let forward: (@Sendable (TransportEvent<Int>) -> Void)? = lock.withLock {
            guard !_holding else {
                held.append(event)
                return nil
            }
            return _forward
        }
        forward?(event)
    }

    /// Stops holding and returns what was held.
    func release() -> [TransportEvent<Int>] {
        lock.withLock {
            defer { (held, _holding) = ([], false) }
            return held
        }
    }
}
