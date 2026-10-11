import Foundation
import PlaybackRender
import PlaybackRenderTestSupport
@_spi(Testing) import PlaybackPlayer

/// A `Player<Item>` on the fake output, fake session, manual pump and manual decode, with transport
/// events delivered by hand so every step is chosen, not raced. Open so a package test can add its
/// own fixtures; an app uses it as is.
@MainActor
open class PlayerTestRig<Item: Hashable & Sendable> {
    public let output = FakeAudioOutput()
    public let timer = ManualPumpTimer()
    public let executor = ManualExecutor()
    public let session = FakeAudioSession()
    public private(set) var player: Player<Item>!
    private let events: AsyncStream<PlayerEvent<Item>>
    private let gate = EventGate()

    public init(makeSource: @escaping ItemSourceFactory<Item>) {
        let (output, timer, executor, gate) = (output, timer, executor, gate)
        player = Player(makeSource: makeSource, session: session) { onEvent in
            gate.forward = onEvent
            return Transport(output: output, timer: timer, executor: executor) { gate.send($0) }
        }
        events = player.events
    }

    /// Runs `body` and returns the transport events it caused, kept from the player as if still on
    /// their way to the main actor; `deliver` hands them over.
    @_spi(Testing)
    public func inFlight(_ body: () -> Void) -> [TransportEvent<Int>] {
        gate.holding = true
        body()
        timer.sync()
        return gate.release()
    }

    @_spi(Testing)
    public func deliver(_ events: [TransportEvent<Int>]) {
        events.forEach(gate.send)
        player.drainTransportEvents()
    }

    /// Runs every transport call made so far and delivers its events.
    public func settle() {
        timer.sync()
        player.drainTransportEvents()
    }

    /// One pump: decode jobs, then the feeder's tick, then the events it sent.
    public func pump() {
        timer.sync()
        executor.runUntilIdle()
        timer.fire()
        player.drainTransportEvents()
    }

    /// Pumps every quarter second of output clock for `seconds`, then once more.
    public func run(for seconds: TimeInterval) {
        for _ in 0..<Int(seconds * 4) {
            pump()
            output.advance(by: 0.25)
        }
        pump()
    }

    /// Drops the player, which finishes its event stream, and returns everything it sent.
    public func finish() async -> [PlayerEvent<Item>] {
        player = nil
        var all: [PlayerEvent<Item>] = []
        for await event in events { all.append(event) }
        return all
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
