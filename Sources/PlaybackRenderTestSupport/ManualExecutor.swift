import Foundation
@_spi(Testing) import PlaybackRender

/// Holds the sequencer's decode jobs until the test runs them, so every interleaving is chosen, not raced.
public final class ManualExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [@Sendable () -> Void] = []

    public init() {}

    public var queued: Int { lock.withLock { jobs.count } }

    public func run(_ job: @escaping @Sendable () -> Void) {
        lock.withLock { jobs.append(job) }
    }

    @discardableResult
    public func runNext() -> Bool {
        guard let job = lock.withLock({ () -> (@Sendable () -> Void)? in jobs.isEmpty ? nil : jobs.removeFirst() }) else { return false }
        job()
        return true
    }

    public func runUntilIdle() {
        while runNext() {}
    }
}

@_spi(Testing) extension ManualExecutor: SequencerExecutor {}
