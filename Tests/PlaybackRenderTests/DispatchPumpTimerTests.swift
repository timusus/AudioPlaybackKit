import Foundation
@testable @_spi(Testing) import PlaybackRender
import XCTest

/// The real timer in wall time: the transport relies on an armed deadline firing once, not repeating.
final class DispatchPumpTimerTests: XCTestCase {
    func testAnArmedDeadlineFiresOnceAndThenNotAgainUnarmed() {
        let timer = DispatchPumpTimer()
        let queue = DispatchQueue(label: "pump")
        let fired = expectation(description: "fired")
        let firedAgain = expectation(description: "fired again")
        firedAgain.isInverted = true
        let count = Counter()
        timer.start(queue: queue) {
            switch count.increment() {
            case 1: fired.fulfill()
            default: firedAgain.fulfill()
            }
        }
        defer { timer.cancel() }
        queue.sync { timer.arm(after: 0.01) }

        wait(for: [fired], timeout: 2)
        wait(for: [firedAgain], timeout: 0.3)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
