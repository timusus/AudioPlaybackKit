import Foundation

/// What calls the transport's pump: a dispatch timer, or a hand-fired fake in tests.
protocol PumpTimer: AnyObject, Sendable {
    /// Calls `tick` on `queue` every `interval` until cancelled.
    func start(interval: TimeInterval, queue: DispatchQueue, tick: @escaping @Sendable () -> Void)
    func cancel()
}

final class DispatchPumpTimer: PumpTimer, @unchecked Sendable {
    private var source: (any DispatchSourceTimer)?

    func start(interval: TimeInterval, queue: DispatchQueue, tick: @escaping @Sendable () -> Void) {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler(handler: tick)
        source.resume()
        self.source = source
    }

    func cancel() {
        source?.cancel()
    }
}
