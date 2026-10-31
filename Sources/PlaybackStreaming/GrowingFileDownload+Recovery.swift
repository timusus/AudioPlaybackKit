import Foundation
import PlaybackDecode

// MARK: - Ending, resuming and requesting a transaction

extension GrowingFileDownload {

    /// The current transaction delivers no more. Retryable with retries left: after a backoff, a
    /// resume from the frontier or a restart at the decoder's position (``retryCurrent(now:)``),
    /// the file still read until then. Otherwise the read reports `reason` at the frontier, and a
    /// failure no retry fixes (a page, a full disk) deletes the file.
    ///
    /// An outage the host never answered spends no attempt while the link window lasts: the read
    /// waits through it, which the player shows as buffering, instead of failing a second into it.
    /// The window runs from when the link went quiet: `quietSince` when given (a silent
    /// body's last byte), else the start of the attempt nothing answered.
    ///
    /// `refused`: the host said no to this URL (a `4xx`, a page). That, or no answer at all, from
    /// the chain's remembered end forgets it: a signed hop may have expired. `pathChanged`: the
    /// source ended the request itself for a new network path, so no answer yet is not the end's.
    mutating func end(
        _ reason: StreamFailure, retryable: Bool, refused: Bool = false, pathChanged: Bool = false,
        quietSince: TimeInterval? = nil, now: TimeInterval
    ) {
        guard let tx = current else { return }
        current?.ended = true
        effects.append(.cancelTask)
        if tx.remembered, refused || (!tx.answered && !pathChanged), let end = finalURL {
            finalURL = nil
            // Without a chain there is nothing to walk again, so no longer wait for it either.
            chainEndForgotten = end != url
        }
        let decision = retry.failed(
            answered: tx.answered, retryable: retryable,
            quietSince: quietSince ?? (tx.answered ? nil : tx.attemptStartedAt), now: now
        )
        guard case .retry(let backoff) = decision else {
            downloadLog.error("download: failed gen=\(tx.generation) \(reason.detail, privacy: .public)")
            if !retryable { retireCurrent(discardingFile: true) }
            failure = reason
            effects.append(.wake)
            return
        }
        let attempt = retry.failuresInRow
        downloadLog.error(
            "download: retry gen=\(tx.generation) attempt=\(attempt) answered=\(tx.answered) \(reason.detail, privacy: .public)"
        )
        effects.append(.schedule(.retry(transaction: tx.id), after: backoff))
    }

    /// The retry ``end(_:retryable:refused:pathChanged:quietSince:now:)`` scheduled. A file that
    /// holds the decoder's position is resumed from its frontier, keeping every byte ahead of the
    /// decoder; anything else (nothing proven in it yet, a seek that left it, a host that ignores
    /// ranges) restarts at the decoder's position. Neither is the seek's: a restart carries no seek
    /// generation and claims none, and a resume keeps the one its transaction had.
    mutating func retryCurrent(now: TimeInterval) {
        guard let tx = current else { return }
        let resumable = !rangeIgnored && file.exists && !file.isCached && !tx.sniffPending
            && tx.written > 0 && offset >= tx.base && offset <= tx.frontier && tx.bodyEnd.map { tx.frontier < $0 } ?? true
        guard resumable else {
            start(at: offset, seekGeneration: nil, retrying: true)
            return
        }
        resume(now: now)
    }

    /// Asks for the current transaction's file from its frontier on, with `If-Range`, in the same
    /// transaction: a retry's resume, or the end of a read-ahead pause. A fresh attempt with the
    /// retry's short wait; nothing answering it starts the link window from when it went out.
    /// The request starts the overlap before the frontier, which its `206` must start at.
    mutating func resume(now: TimeInterval) {
        guard let tx = current else { return }
        let from = overlapStart(before: tx.frontier)
        current?.ended = false
        current?.paused = false
        current?.answered = false
        current?.resumeAt = from
        current?.remembered = finalURL != nil
        send(from: from, ifRange: tx.entityTag, retrying: true, now: now)
        let decoder = offset, frontier = tx.frontier
        downloadLog.info("download: resume gen=\(tx.generation) at=\(frontier) from=\(from) decoder=\(decoder)")
    }

    /// The read-ahead cap applies to `tx`: a cap was given, the path costs, and the host answered
    /// its range with a `206`, so a resume is not answered from byte 0. A host that ignores ranges
    /// (a `200`, even to `bytes=0-`) downloads whole.
    func isCapped(_ tx: Transaction) -> Bool {
        readAhead != nil && pathIsExpensive && !rangeIgnored && tx.rangeHonoured
    }

    /// Cancels the request once the frontier is the read-ahead ahead of the decoder. No failure:
    /// nothing is spent and no timer starts; the file stays, and a read resumes it (``read(maxLength:now:)``).
    mutating func pauseIfFarAhead(now: TimeInterval) {
        guard let readAhead, let tx = current, isCapped(tx), !tx.ended, tx.frontier - offset >= readAhead, tx.frontier < min(tx.totalLength ?? .max, tx.end ?? .max) else { return }
        current?.ended = true
        current?.paused = true
        let rate = downloadBytesPerSecond(now: now)
        current?.rateAtPause = rate
        effects.append(.cancelTask)
        let decoder = offset
        downloadLog.info("download: pause gen=\(tx.generation) at=\(tx.frontier) decoder=\(decoder)")
    }

    /// The current transaction's next request, and its wait for a response: ``target(retrying:)``'s,
    /// cut at the link window's end. The response cancels it; its firing ends the transaction like a drop.
    mutating func send(from: Int64, ifRange: String?, retrying: Bool, now: TimeInterval) {
        let target = target(retrying: retrying)
        attemptsSent += 1
        current?.attempt = attemptsSent
        current?.attemptStartedAt = now
        current?.bodyAt = from
        let wait = min(target.timeout, retry.linkWindowLeft(now: now) ?? target.timeout)
        effects.append(.schedule(.response(attempt: attemptsSent), after: wait))
        effects.append(.send(Request(attempt: attemptsSent, url: target.url, from: from, end: current?.bodyEnd, ifRange: ifRange)))
    }

    /// Where the next request goes and how long it waits for its response: the chain's remembered
    /// end when there is one, else the requested URL. A retry waits
    /// ``GrowingFileByteSource/retryRequestTimeoutSeconds`` unless it walks the chain again because
    /// its end was just forgotten; that one, like a transaction's first request, waits
    /// ``GrowingFileByteSource/requestTimeoutSeconds``.
    private mutating func target(retrying: Bool) -> (url: URL, timeout: TimeInterval) {
        defer { chainEndForgotten = false }
        let short = retrying && (finalURL != nil || !chainEndForgotten)
        return (
            finalURL ?? url,
            short ? GrowingFileByteSource.retryRequestTimeoutSeconds : GrowingFileByteSource.requestTimeoutSeconds
        )
    }

    /// Asks for an idle check ``GrowingFileByteSource/idleTimeoutSeconds`` from now (or `seconds`).
    mutating func scheduleIdleCheck(after seconds: TimeInterval = GrowingFileByteSource.idleTimeoutSeconds) {
        guard let tx = current, !tx.idleCheckPending else { return }
        current?.idleCheckPending = true
        effects.append(.schedule(.idle(transaction: tx.id), after: seconds))
    }
}
