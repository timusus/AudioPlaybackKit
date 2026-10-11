import Foundation
@_spi(Testing) import PlaybackRender

/// Fires the transport's pump by hand on its queue, after every call already made.
public final class ManualPumpTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: DispatchQueue?
    private var tick: (@Sendable () -> Void)?
    private var _wakes = 0

    public init() {}

    public func start(interval: TimeInterval, queue: DispatchQueue, tick: @escaping @Sendable () -> Void) {
        lock.withLock {
            self.queue = queue
            self.tick = tick
        }
    }

    public func cancel() {}

    /// Wakes are only counted: a test fires the pump they ask for itself.
    public var wakes: Int { lock.withLock { _wakes } }

    public func wake() {
        lock.withLock { _wakes += 1 }
    }

    /// Runs one pump and returns once it has finished.
    public func fire() {
        let (queue, tick) = lock.withLock { (queue!, tick!) }
        queue.sync(execute: tick)
    }

    /// Waits for every call already made, without pumping.
    public func sync() {
        lock.withLock { queue! }.sync {}
    }
}

@_spi(Testing) extension ManualPumpTimer: PumpTimer {}
