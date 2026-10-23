import Foundation
import PlaybackRender

/// The token a callback checks on the main actor, known only once the transport has returned it.
/// Before that it counts as live; once set, a released or cancelled token is not.
private final class DeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var assigned = false
    private weak var token: TimeObserverToken?

    func assign(_ token: TimeObserverToken) {
        lock.withLock {
            self.token = token
            assigned = true
        }
    }

    var isOpen: Bool {
        lock.withLock { !assigned || token?.isCancelled == false }
    }
}

/// media3 has no periodic callback, so these follow AVPlayer's `addPeriodicTimeObserver` and
/// `addBoundaryTimeObserver`: the only wakeups while playing are the ones an observer asks for (ADR-0031).
extension Player {
    /// Calls `callback` on the main actor every `interval` of wall time while the clock runs, on
    /// multiples of it, and not while paused or buffering. Keep the token: releasing it removes the
    /// observer, and no call is made after `cancel()` returns, even one already on its way.
    public func addPeriodicObserver(
        interval: TimeInterval,
        using callback: @escaping @MainActor @Sendable () -> Void
    ) -> TimeObserverToken {
        let gate = DeliveryGate()
        let token = transport.addPeriodicObserver(interval: interval) {
            Task { @MainActor in
                if gate.isOpen { callback() }
            }
        }
        gate.assign(token)
        return token
    }

    /// Calls `callback` on the main actor with the item and the time when playback crosses one of
    /// `times` in the item heard. A load or seek landing past a time does not fire it. Keep the token:
    /// releasing it removes the observer, and no call is made after `cancel()` returns.
    public func addBoundaryObserver(
        times: [TimeInterval],
        using callback: @escaping @MainActor @Sendable (Item, TimeInterval) -> Void
    ) -> TimeObserverToken {
        let keyedItems = keyedItems
        let gate = DeliveryGate()
        let token = transport.addBoundaryObserver(times: times) { key, time in
            guard let item = keyedItems.item(for: key) else { return }
            Task { @MainActor in
                if gate.isOpen { callback(item, time) }
            }
        }
        gate.assign(token)
        return token
    }
}
