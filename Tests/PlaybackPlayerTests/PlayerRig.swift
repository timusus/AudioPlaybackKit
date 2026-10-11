import Foundation
import PlaybackRender
import PlaybackRenderTestSupport
import PlaybackPlayerTestSupport
@_spi(Testing) @testable import PlaybackPlayer

/// The shared rig over `FakeItemFactory`'s string items, plus the event-list helpers these tests share.
@MainActor
final class PlayerRig: PlayerTestRig<String> {
    struct Transition: Equatable {
        var from: Int?
        var to: Int?
        var reason: TransitionReason
    }

    let factory: FakeItemFactory

    init() {
        let factory = FakeItemFactory()
        self.factory = factory
        super.init { try factory.make($0) }
    }

    /// The first sample written after the first `skipping` writes: the frame decode landed on.
    func firstSampleWritten(skipping: Int) -> Float? {
        output.enqueues.dropFirst(skipping).first?.samples.first
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
