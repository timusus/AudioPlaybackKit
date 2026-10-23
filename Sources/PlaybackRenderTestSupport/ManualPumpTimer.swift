import Foundation
@_spi(Testing) import PlaybackRender

/// Fires the transport's pump by hand on its queue, after every call already made.
///
/// The queue stays suspended between `sync`, `fire` and `fireHeld`, so a call made by the test runs at
/// the next pump, never whenever the scheduler gets to it: a call reads the manual clock when it runs.
public final class ManualPumpTimer: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: DispatchQueue?
    private var tick: (@Sendable () -> Void)?
    private var suspended = false
    private var _wakes = 0
    private var _armedDelay: TimeInterval?
    private var _armCount = 0

    public init() {}

    public func start(queue: DispatchQueue, tick: @escaping @Sendable () -> Void) {
        lock.withLock {
            self.queue = queue
            self.tick = tick
            if !suspended {
                queue.suspend()
                suspended = true
            }
        }
    }

    /// A suspended queue must not be released.
    public func cancel() {
        lock.withLock {
            if suspended { queue?.resume() }
            suspended = false
        }
    }

    /// Wakes are only counted: a test fires the pump they ask for itself.
    public var wakes: Int { lock.withLock { _wakes } }

    /// The delay the transport last asked for, nil when it asked for none: nothing is due on the clock.
    public var armedDelay: TimeInterval? { lock.withLock { _armedDelay } }

    /// How many deadlines the transport has armed; a pump that finds nothing due does not count.
    public var armCount: Int { lock.withLock { _armCount } }

    public func arm(after delay: TimeInterval?) {
        lock.withLock {
            _armedDelay = delay
            if delay != nil { _armCount += 1 }
        }
    }

    public func wake() {
        lock.withLock { _wakes += 1 }
    }

    /// Runs one pump and returns once it has finished.
    public func fire() {
        let (queue, tick) = lock.withLock { (self.queue!, self.tick!) }
        running(queue) { queue.sync(execute: tick) }
    }

    /// Queues one pump, as a real timer tick lands, and holds it until the returned release is called,
    /// so a call made in between queues behind a tick that fired first.
    public func fireHeld() -> () -> Void {
        let (queue, tick) = lock.withLock { (self.queue!, self.tick!) }
        queue.async(execute: tick)
        return { [self] in running(queue) { queue.sync {} } }
    }

    /// Waits for every call already made, without pumping.
    public func sync() {
        let queue = lock.withLock { self.queue! }
        running(queue) { queue.sync {} }
    }

    private func running(_ queue: DispatchQueue, _ body: () -> Void) {
        let wasSuspended = lock.withLock { () -> Bool in
            defer { suspended = false }
            return suspended
        }
        if wasSuspended { queue.resume() }
        body()
        if wasSuspended {
            queue.suspend()
            lock.withLock { suspended = true }
        }
    }
}

@_spi(Testing) extension ManualPumpTimer: PumpTimer {}
