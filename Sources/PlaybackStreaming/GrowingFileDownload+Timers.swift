import Foundation
import PlaybackDecode

// MARK: - Timers and the network path

extension GrowingFileDownload {

    /// Every event's first step. While the link window or an attempt's wait runs, a timer comes due within
    /// ``GrowingFileByteSource/requestTimeoutSeconds``; an event 5 s past that found the process suspended,
    /// which says nothing of the link, so the quiet clocks skip the gap.
    mutating func ran(now: TimeInterval) {
        defer { lastRanAt = now }
        guard let last = lastRanAt, now - last > GrowingFileByteSource.requestTimeoutSeconds + 5 else { return }
        let gap = now - last
        retry.suspended(for: gap)
        current?.attemptStartedAt += gap
        current?.lastByteAt += gap
    }

    mutating func fire(_ timer: Timer, now: TimeInterval) -> [Effect] {
        ran(now: now)
        switch timer {
        case .recheck:
            recheckPending = false
            effects.append(.wake)
        case .retry(let id):
            guard !cancelled, current?.id == id else { break }
            retryCurrent(now: now)
        case .response(let attempt):
            guard !cancelled, let tx = current, tx.attempt == attempt, !tx.answered, !tx.ended else { break }
            end(StreamFailure(.network, detail: "no_response_s=\(Int(now - tx.attemptStartedAt))"), retryable: true, now: now)
        case .idle(let id):
            fireIdle(transaction: id, now: now)
        }
        return takeEffects()
    }

    /// Ends the body once it has been silent for the idle timeout: a failure like a drop,
    /// into the retry. Looks again when a chunk came in the meantime, and stops once the
    /// transaction is done with the network. The link went quiet at the last byte, so that
    /// is where the link window starts if nothing answers the retry. Nothing is checked
    /// before the response arrives: that wait is the response timer's, nor once every byte
    /// is in and only the completion is on the way.
    private mutating func fireIdle(transaction id: Int, now: TimeInterval) {
        guard current?.id == id else { return }
        current?.idleCheckPending = false
        guard !cancelled, let tx = current, tx.answered, !tx.ended, !tx.isComplete,
              tx.frontier < min(tx.totalLength ?? .max, tx.bodyEnd ?? .max) else { return }
        let silent = now - tx.lastByteAt
        guard silent >= GrowingFileByteSource.idleTimeoutSeconds else {
            scheduleIdleCheck(after: GrowingFileByteSource.idleTimeoutSeconds - silent)
            return
        }
        end(
            StreamFailure(.network, detail: "idle_s=\(Int(silent)) at=\(tx.frontier)"), retryable: true,
            quietSince: tx.lastByteAt, now: now
        )
    }

    /// A usable network path replaced the one the transaction's connection is on (Wi-Fi gone to
    /// cellular). That connection may never say another word, and the idle check would take
    /// ``GrowingFileByteSource/idleTimeoutSeconds`` to notice; the transaction is ended now
    /// instead, like a drop, and ``Retry`` decides on it as on any other: a resume from the
    /// frontier after the backoff, from the same budget. A transaction done with the network, or
    /// whose every byte is in and only its completion is still on the way, is left alone.
    mutating func pathChanged(now: TimeInterval) -> [Effect] {
        ran(now: now)
        guard !cancelled, let tx = current, !tx.ended, !tx.isComplete,
              tx.frontier < min(tx.totalLength ?? .max, tx.bodyEnd ?? .max) else { return [] }
        end(StreamFailure(.network, detail: "path_changed at=\(tx.frontier)"), retryable: true, pathChanged: true, now: now)
        return takeEffects()
    }

    /// The decoder probed a stream of `duration`: its bitrate is the total length over it, whichever
    /// of the two is known first.
    mutating func streamProbed(duration: TimeInterval) {
        guard duration > 0, duration.isFinite else { return }
        probedDuration = duration
    }

    /// The path's cost, on every path the monitor reports. A paused transaction resumes at once
    /// on a path that no longer costs; one that costs pauses at its next chunk.
    mutating func pathCost(isExpensive: Bool, now: TimeInterval) -> [Effect] {
        ran(now: now)
        pathIsExpensive = isExpensive
        if !cancelled, let tx = current, tx.paused, !isCapped(tx) { resume(now: now) }
        return takeEffects()
    }

    /// The system refused the origin's certificate and the user trusted no such leaf: the read fails
    /// at once, with no retry.
    mutating func certificateRejected(attempt: Int, now: TimeInterval) -> [Effect] {
        ran(now: now)
        guard !cancelled, let tx = current, tx.attempt == attempt, !tx.ended else { return [] }
        end(
            StreamFailure(
                .network, detail: GrowingFileConnectionPolicy.untrustedCertificateReason,
                urlError: URLError(.serverCertificateUntrusted)
            ),
            retryable: false, now: now
        )
        return takeEffects()
    }
}
