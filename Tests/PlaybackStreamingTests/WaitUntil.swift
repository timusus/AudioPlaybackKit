import Foundation
import PlaybackStreamingTestSupport

/// Wakes on a change to the source, the loopback server, the test clock or the event recorder,
/// each of which notifies ``ChangeSignal``. The timeout only bounds a failure on a loaded machine.
func waitUntil(_ timeout: TimeInterval = 20, _ condition: () -> Bool) -> Bool {
    ChangeSignal.shared.wait(timeout: timeout, until: condition)
}
