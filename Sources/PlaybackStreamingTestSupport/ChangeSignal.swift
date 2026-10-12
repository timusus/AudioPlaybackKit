import Foundation

/// Wakes a test when anything it observes changes, so it waits on state instead of a timer.
/// Every observed thing (the byte source, the loopback server, a test clock, an event recorder)
/// calls ``notify()`` after a change; ``wait(timeout:until:)`` rechecks its condition on each.
/// One process-wide instance: a wake meant for another test only costs a recheck.
public final class ChangeSignal: @unchecked Sendable {

    public static let shared = ChangeSignal()

    private let condition = NSCondition()
    private var version = 0

    public init() {}

    public func notify() {
        condition.lock()
        version += 1
        condition.broadcast()
        condition.unlock()
    }

    /// Whether `predicate` held before `timeout` ran out. The timeout only bounds a failure: a
    /// predicate that holds returns at once. `predicate` runs outside the signal's lock, so it may
    /// take the observed object's own; the version check keeps a change landing between the
    /// predicate and the wait from being missed.
    public func wait(timeout: TimeInterval = 20, until predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            condition.lock()
            let seen = version
            condition.unlock()
            if predicate() { return true }
            condition.lock()
            while version == seen {
                if !condition.wait(until: deadline) {
                    condition.unlock()
                    return predicate()
                }
            }
            condition.unlock()
        }
    }
}
