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
    private var source: (any DispatchSourceTimer)?
    private var queue: DispatchQueue?
    private var tick: (@Sendable () -> Void)?

    func start(queue: DispatchQueue, tick: @escaping @Sendable () -> Void) {
        self.queue = queue
        self.tick = tick
        // Strict: a coalesced one-shot fires up to 150 ms late and every re-arm compounds it, which
        // stretched the 10 Hz position cadence to 4 Hz and delayed the end of the item.
        let source = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        source.schedule(deadline: .distantFuture)
        source.setEventHandler(handler: tick)
        source.resume()
        self.source = source
    }

    func arm(after delay: TimeInterval?) {
        if let delay {
            source?.schedule(deadline: .now() + max(delay, 0))
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
