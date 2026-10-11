import Foundation

/// What calls the transport's pump: a dispatch timer, or a hand-fired fake in tests.
@_spi(Testing) public protocol PumpTimer: AnyObject, Sendable {
    /// Calls `tick` on `queue` every `interval` until cancelled.
    func start(interval: TimeInterval, queue: DispatchQueue, tick: @escaping @Sendable () -> Void)
    func cancel()
    /// Calls `tick` once now, from any thread: something the pump waits on happened, and waiting
    /// out the interval would be heard as silence.
    func wake()
}

final class DispatchPumpTimer: PumpTimer, @unchecked Sendable {
    private var source: (any DispatchSourceTimer)?
    private var queue: DispatchQueue?
    private var tick: (@Sendable () -> Void)?

    func start(interval: TimeInterval, queue: DispatchQueue, tick: @escaping @Sendable () -> Void) {
        self.queue = queue
        self.tick = tick
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler(handler: tick)
        source.resume()
        self.source = source
    }

    func wake() {
        guard let queue, let tick else { return }
        queue.async(execute: tick)
    }

    func cancel() {
        source?.cancel()
    }
}
