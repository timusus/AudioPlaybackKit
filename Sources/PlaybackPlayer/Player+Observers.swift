import Foundation
import PlaybackRender

/// media3 has no periodic callback, so these follow AVPlayer's `addPeriodicTimeObserver` and
/// `addBoundaryTimeObserver`: the only wakeups while playing are the ones an observer asks for (ADR-0031).
extension Player {
    /// Calls `callback` on the main actor every `interval` of wall time while the clock runs, on
    /// multiples of it, and not while paused or buffering. Keep the token: releasing it removes the observer.
    public func addPeriodicObserver(
        interval: TimeInterval,
        using callback: @escaping @MainActor @Sendable () -> Void
    ) -> TimeObserverToken {
        transport.addPeriodicObserver(interval: interval) {
            Task { @MainActor in callback() }
        }
    }

    /// Calls `callback` on the main actor with the item and the time when playback crosses one of
    /// `times` in the item heard. A load or seek landing past a time does not fire it. Keep the token:
    /// releasing it removes the observer.
    public func addBoundaryObserver(
        times: [TimeInterval],
        using callback: @escaping @MainActor @Sendable (Item, TimeInterval) -> Void
    ) -> TimeObserverToken {
        let keyedItems = keyedItems
        return transport.addBoundaryObserver(times: times) { key, time in
            guard let item = keyedItems.item(for: key) else { return }
            Task { @MainActor in callback(item, time) }
        }
    }
}
