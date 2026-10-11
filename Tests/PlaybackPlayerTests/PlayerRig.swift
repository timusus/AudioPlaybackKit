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
    private(set) var player: Player<String>!
    private let events: AsyncStream<PlayerEvent<String>>

    init() {
        let (output, timer, executor, factory) = (output, timer, executor, factory)
        player = Player(makeSource: { try factory.make($0) }) { onEvent in
            Transport(output: output, timer: timer, executor: executor, onEvent: onEvent)
        }
        events = player.events
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
}
