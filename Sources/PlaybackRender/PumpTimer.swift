import Foundation

/// What calls the transport's pump: a one-shot dispatch timer the transport re-arms after each pump
/// for the next work due on the clock, or a hand-fired fake in tests.
@_spi(Testing) public protocol PumpTimer: AnyObject, Sendable {
    /// Sets the tick's queue and handler; nothing is armed until `arm`.
    func start(queue: DispatchQueue, tick: @escaping @Sendable () -> Void)
    /// Replaces any armed deadline: calls `tick` once on the queue after `delay`. Nil arms nothing.
    /// Called on that queue.
    func arm(after delay: TimeInterval?)
    func cancel()
    /// Calls `tick` once now, from any thread: something the pump waits on happened, and waiting
    /// for the next deadline would be heard as silence.
    func wake()
}

final class DispatchPumpTimer: PumpTimer, @unchecked Sendable {
    private static let maxLeeway: TimeInterval = 0.02
    private var source: (any DispatchSourceTimer)?
    private var queue: DispatchQueue?
    private var tick: (@Sendable () -> Void)?

    func start(queue: DispatchQueue, tick: @escaping @Sendable () -> Void) {
        self.queue = queue
        self.tick = tick
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .distantFuture)
        source.setEventHandler(handler: tick)
        source.resume()
        self.source = source
    }

    func arm(after delay: TimeInterval?) {
        if let delay {
            // A small explicit leeway in place of the default (up to 150 ms on macOS) lets the OS batch wakeups;
            // deadlines sit on the output clock, so a late tick delays only itself, never the ones after it.
            let leeway = min(max(delay, 0) * 0.1, Self.maxLeeway)
            source?.schedule(deadline: .now() + max(delay, 0), leeway: .nanoseconds(Int(leeway * 1e9)))
        } else {
            source?.schedule(deadline: .distantFuture)
        }
    }

    func wake() {
        guard let queue, let tick else { return }
        queue.async(execute: tick)
    }

    func cancel() {
        source?.cancel()
    }
}
