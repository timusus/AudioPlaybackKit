import Foundation
import PlaybackRender
import PlaybackRenderTestSupport
@_spi(Testing) import PlaybackPlayerTestSupport
@_spi(Testing) @testable import PlaybackPlayer

/// The shared rig over `FakeItemFactory`'s string items, plus the event-list helpers these tests share.
@MainActor
final class PlayerRig {
    struct Transition: Equatable {
        var from: Int?
        var to: Int?
        var reason: TransitionReason
    }

    let factory: FakeItemFactory<String>
    private let base: PlayerTestRig<String>

    init() {
        // Each name's samples start at its own base (a 0, b 1000, c 2000, ...).
        let names = ["a", "b", "c", "d", "x", "y"]
        let factory = FakeItemFactory<String> { Float(names.firstIndex(of: $0)! * 1000) }
        self.factory = factory
        base = PlayerTestRig { try factory.make($0) }
    }

    var output: FakeAudioOutput { base.output }
    var timer: ManualPumpTimer { base.timer }
    var executor: ManualExecutor { base.executor }
    var session: FakeAudioSession { base.session }
    var player: Player<String>! { base.player }

    func inFlight(_ body: () -> Void) -> [TransportEvent<Int>] { base.inFlight(body) }
    func deliver(_ events: [TransportEvent<Int>]) { base.deliver(events) }
    func settle() { base.settle() }
    func pump() { base.pump() }
    func run(for seconds: TimeInterval) { base.run(for: seconds) }
    func finish() async -> [PlayerEvent<String>] { await base.finish() }

    /// The first sample written after the first `skipping` writes: the frame decode landed on.
    func firstSampleWritten(skipping: Int) -> Float? {
        output.enqueues.dropFirst(skipping).first?.samples.first
    }

    enum Kind: Equatable {
        case itemTransition, itemFailed, seekLanded, seekAdjusted, recoveredPaused, playWhenReadyChanged
    }

    /// Each event's case, in the order sent. The telemetry events are left out: they follow the
    /// audio, not the calls, and `PlayerTelemetryEventTests` pins them.
    static func kinds(_ events: [PlayerEvent<String>]) -> [Kind] {
        events.compactMap {
            switch $0 {
            case .itemTransition: .itemTransition
            case .itemFailed: .itemFailed
            case .seekLanded: .seekLanded
            case .seekAdjusted: .seekAdjusted
            case .recoveredPaused: .recoveredPaused
            case .playWhenReadyChanged: .playWhenReadyChanged
            case .firstAudioRendered, .bufferingStarted, .bufferingEnded: nil
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

    static func seeksAdjusted(_ events: [PlayerEvent<String>]) -> [Adjustment] {
        events.compactMap {
            guard case let .seekAdjusted(index, requested, position) = $0 else { return nil }
            return Adjustment(index: index, requested: requested, position: position)
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

    struct Adjustment: Equatable {
        var index: Int
        var requested: TimeInterval
        var position: TimeInterval
    }
}
