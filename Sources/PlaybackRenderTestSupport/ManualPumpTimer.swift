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
        // `self.` here and below: Swift 6.2 binds a bare name to the local being declared.
        let (queue, tick) = lock.withLock { (self.queue!, self.tick!) }
        queue.sync(execute: tick)
    }

    /// Queues one pump, as a real timer tick lands, and holds it until the returned release is called,
    /// so a call made in between queues behind a tick that fired first.
    public func fireHeld() -> () -> Void {
        let (queue, tick) = lock.withLock { (self.queue!, self.tick!) }
        queue.suspend()
        queue.async(execute: tick)
        return { queue.resume() }
    }

    /// Waits for every call already made, without pumping.
    public func sync() {
        lock.withLock { queue! }.sync {}
    }
}

@_spi(Testing) extension ManualPumpTimer: PumpTimer {}
