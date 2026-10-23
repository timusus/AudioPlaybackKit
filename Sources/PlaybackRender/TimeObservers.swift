import Foundation

/// Removes its observer on `cancel()` or when released; cancelling twice does nothing.
public final class TimeObserverToken: @unchecked Sendable {
    private let lock = NSLock()
    private var remove: (@Sendable () -> Void)?

    init(remove: @escaping @Sendable () -> Void) {
        self.remove = remove
    }

    deinit { cancel() }

    public func cancel() {
        let remove = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { self.remove = nil }
            return self.remove
        }
        remove?()
    }
}

/// The transport's periodic and boundary observers (ADR-0031), confined to its queue. Each queue
/// entry fires what is due and returns the output times at which the next ones fall due.
struct TimeObservers<Item> {
    /// What is heard, as the transport reports it, and the taken calls it belongs to.
    struct Heard {
        var id: Int
        var item: Item
        var seconds: TimeInterval
        var epoch: Int
    }

    private struct Periodic {
        var interval: TimeInterval
        var callback: @Sendable () -> Void
        var due: TimeInterval?
    }

    private struct Boundary {
        var times: [TimeInterval]
        var callback: @Sendable (Item, TimeInterval) -> Void
        var last: (id: Int, epoch: Int, seconds: TimeInterval)?
    }

    private var periodic: [Int: Periodic] = [:]
    private var boundaries: [Int: Boundary] = [:]

    mutating func addPeriodic(key: Int, interval: TimeInterval, _ callback: @escaping @Sendable () -> Void) {
        periodic[key] = Periodic(interval: interval, callback: callback)
    }

    mutating func addBoundary(key: Int, times: [TimeInterval], _ callback: @escaping @Sendable (Item, TimeInterval) -> Void) {
        boundaries[key] = Boundary(times: times.sorted(), callback: callback)
    }

    mutating func remove(_ key: Int) {
        periodic[key] = nil
        boundaries[key] = nil
    }

    /// `clock` is nil while the clock is stopped, `heard` while nothing is or a call is not yet taken.
    /// `heardTime` maps a time in an item to the output time it is heard at, nil until it is written.
    mutating func fire(
        clock: TimeInterval?,
        heard: Heard?,
        heardTime: (Int, TimeInterval) -> TimeInterval?
    ) -> [TimeInterval] {
        var deadlines: [TimeInterval] = []
        for key in periodic.keys.sorted() {
            guard var observer = periodic[key] else { continue }
            if let clock {
                // A clock within 1 % of an interval short of a multiple is at it, so float noise never arms ~0.
                if let due = observer.due, clock + 0.01 * observer.interval >= due { observer.callback() }
                let due = ((clock / observer.interval + 0.01).rounded(.down) + 1) * observer.interval
                observer.due = due
                deadlines.append(due)
            } else {
                observer.due = nil
            }
            periodic[key] = observer
        }
        guard let heard else { return deadlines }
        for key in boundaries.keys.sorted() {
            guard var observer = boundaries[key] else { continue }
            // A load, seek or crossing landing past a time does not fire it: only playing across does.
            // The heard position steps back on a re-anchor or a latency change; `last` only moves forward
            // within one item and call, so a time crossed once is not crossed again.
            var seen = heard.seconds
            if let last = observer.last, last.id == heard.id, last.epoch == heard.epoch {
                for time in observer.times where time > last.seconds && time <= heard.seconds {
                    observer.callback(heard.item, time)
                }
                seen = max(seen, last.seconds)
            }
            observer.last = (heard.id, heard.epoch, seen)
            boundaries[key] = observer
            if clock != nil, let next = observer.times.first(where: { $0 > heard.seconds }),
               let due = heardTime(heard.id, next) {
                deadlines.append(due)
            }
        }
        return deadlines
    }
}
