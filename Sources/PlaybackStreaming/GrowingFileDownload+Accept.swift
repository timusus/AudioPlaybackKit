import Foundation
import PlaybackDecode

// MARK: - Accepting a response

extension GrowingFileDownload {

    /// The response to the request `attempt`: whether its body is taken.
    mutating func received(_ response: Response, attempt: Int, now: TimeInterval) -> (allow: Bool, effects: [Effect]) {
        ran(now: now)
        guard !cancelled, let tx = current, tx.attempt == attempt, !tx.ended else { return (false, []) }
        let allow = accept(response, tx, now: now)
        return (allow, takeEffects())
    }

    private typealias ContentRange = (start: Int64, total: Int64?)

    private mutating func accept(_ response: Response, _ tx: Transaction, now: TimeInterval) -> Bool {
        // The link is up, whatever the host says next.
        current?.answered = true
        retry.linkAnswered()
        let status = response.status
        let range = Self.contentRange(response.contentRange)
        if let total = Self.totalEndingAt(tx.frontier, status: status, contentRange: response.contentRange),
           lastKnownTotalLength.map({ $0 == total }) ?? true {
            return acceptOpenAtEnd(response, tx, total: total, now: now)
        }
        if let resumeAt = tx.resumeAt {
            return acceptResume(response, tx, at: resumeAt, range: range, now: now)
        }
        return acceptFresh(response, tx, range: range, now: now)
    }

    /// The host says the resource ends exactly where this transaction starts: a `416`
    /// with `bytes */N`, or a range clamped to the last byte, at position N. As media3
    /// does, that is a zero-length open: the length is learned and the read is at its
    /// end. A resume at the frontier is the same open, there. A total that differs from
    /// the one already known (the file shrank) is refused like any other answer.
    private mutating func acceptOpenAtEnd(_ response: Response, _ tx: Transaction, total: Int64, now: TimeInterval) -> Bool {
        let status = response.status
        downloadLog.info("download: open_at_end gen=\(tx.generation) status=\(status) total=\(total)")
        current?.resumeAt = nil
        current?.ended = true
        current?.isComplete = true
        current?.totalLength = total
        lastKnownTotalLength = total
        promoteIfWhole()
        recordIdentity(response)
        if finalURL == nil { finalURL = response.url }
        recordResponse(tx, status: status, now: now)
        effects.append(.emit(.transaction(base: tx.base, generation: tx.generation, seekGeneration: tx.seekGeneration, httpStatus: status)))
        effects.append(.emit(.download(frontier: tx.frontier, downloadBytesPerSecond: downloadBytesPerSecond(now: now), complete: true)))
        effects.append(.wake)
        return false
    }

    /// The answer to a resume's request: the same bytes from the frontier on, or a restart.
    private mutating func acceptResume(
        _ response: Response, _ tx: Transaction, at resumeAt: Int64, range: ContentRange?, now: TimeInterval
    ) -> Bool {
        let status = response.status
        let contentRange = response.contentRange
        current?.resumeAt = nil
        // The same bytes from the frontier on, as far as the host lets that be checked:
        // the start asked for, and the total the file was begun under.
        let sameTotal = range?.total.map { tx.totalLength == nil || $0 == tx.totalLength } ?? true
        let wholeLength = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        switch status {
        case 206 where range?.start == resumeAt && sameTotal:
            break
        case 200..<300 where status != 206 && resumeAt == 0 && wholeLength != nil
            && (tx.totalLength == nil || wholeLength == tx.totalLength):
            // From byte 0 a whole body is the range asked for (media3 DefaultHttpDataSource
            // skips bytes only when the position is not 0). Without a length it could be any stream.
            break
        case 200..<300, 416:
            // The range ignored, or a different file behind the URL: not these bytes' end.
            downloadLog.warning(
                "download: resume_refused gen=\(tx.generation) status=\(status) content-range=\(contentRange ?? "-", privacy: .public)"
            )
            // A retry's restart, to the end of the chain that just answered: the short wait.
            // Bytes these can no longer be checked against are not kept.
            if finalURL == nil { finalURL = response.url }
            start(at: offset, seekGeneration: nil, retrying: true, discardingFile: true)
            return false
        default:
            end(Self.statusFailure(status, contentRange), retryable: true, refused: (400..<500).contains(status), now: now)
            return false
        }
        if Self.isMedia(mimeType: response.mimeType) == false {
            end(Self.notAudio("content-type=\(response.mimeType ?? "?")"), retryable: tx.remembered, refused: true, now: now)
            return false
        }
        // A whole body is a new response's bytes from 0, kept in this generation since its base
        // and frontier stand; a 206 continues the body the identity already names.
        if status != 206 { recordIdentity(response) }
        if tx.totalLength == nil { current?.totalLength = range?.total ?? (status == 206 ? nil : wholeLength) }
        lastKnownTotalLength = current?.totalLength
        if let total = current?.totalLength { effects.append(.makeRoom(bytes: total - resumeAt)) }
        if finalURL == nil { finalURL = response.url }
        recordResponse(tx, status: status, now: now)
        current?.lastByteAt = now
        scheduleIdleCheck()
        effects.append(.wake)
        return true
    }

    /// The answer to a transaction's first request: its status, its type, then whether the
    /// resource is still the one the file holds.
    private mutating func acceptFresh(_ response: Response, _ tx: Transaction, range: ContentRange?, now: TimeInterval) -> Bool {
        guard acceptFreshStatus(response, tx, range: range, now: now), let accepted = current else { return false }
        switch Self.isMedia(mimeType: response.mimeType) {
        case false?:
            // From the remembered end of the chain, the page may be its signature expiring.
            end(Self.notAudio("content-type=\(response.mimeType ?? "?")"), retryable: accepted.remembered, refused: true, now: now)
            return false
        case nil: current?.sniffPending = accepted.base == 0
        case true?: break
        }
        return commitFresh(response, accepted, range: range, now: now)
    }

    private mutating func acceptFreshStatus(
        _ response: Response, _ tx: Transaction, range: ContentRange?, now: TimeInterval
    ) -> Bool {
        let status = response.status
        let contentRange = response.contentRange
        switch status {
        case 206 where range?.start == tx.bodyAt:
            current?.rangeHonoured = true
        case _ where status == 416 || (status == 206 && (range?.total).map { $0 < tx.base } ?? false):
            failOutOfRange("status=\(status) at=\(tx.base) content-range=\(contentRange ?? "-")")
            return false
        case 200..<300 where status != 206:
            // As media3's DefaultHttpDataSource, any 2xx is success; one other than 206 is a whole body.
            current?.end = nil
            current?.checkEnd = nil
            current?.bodyAt = 0
            if tx.base > 0 || tx.end != nil { restartAsWholeBody(tx) }
        default:
            end(Self.statusFailure(status, contentRange), retryable: true, refused: (400..<500).contains(status), now: now)
            return false
        }
        return true
    }

    /// The host ignored the range (a bounded one from 0 too: later covered bytes need
    /// comparing): this body is the file from byte 0, and the read
    /// waits for its position to arrive. Restarting would only get 200 again. A new
    /// base is a new generation, so a frontier never moves back within one.
    private mutating func restartAsWholeBody(_ tx: Transaction) {
        if !rangeIgnored {
            let host = url.host ?? "?"
            downloadLog.warning("download: range_ignored host=\(host, privacy: .public) asked=\(tx.base)")
        }
        rangeIgnored = true
        nextGeneration()
        // The run at byte 0 comes again: compared like any overlap, and written past (ADR-0016).
        current?.base = file.ranges.run(containing: 0)?.upperBound ?? 0
        current?.generation = generation
        // Byte 0 is not where the seek landed, so it is no anchor for it.
        current?.seekGeneration = nil
    }

    /// Takes the body of a first response, unless the resource changed behind the URL.
    private mutating func commitFresh(_ response: Response, _ accepted: Transaction, range: ContentRange?, now: TimeInterval) -> Bool {
        // A bounded request's length ends at its bound, not the resource's end. The body starts at
        // the overlap, before the base.
        let total = range?.total
            ?? (response.expectedContentLength > 0 && accepted.end == nil ? response.expectedContentLength + accepted.bodyAt : nil)
        let strongTag = response.entityTag.flatMap { $0.hasPrefix("W/") ? nil : $0 }
        let changedTotal = total != nil && lastKnownTotalLength != nil && total != lastKnownTotalLength
        let changedTag = strongTag != nil && file.entityTag != nil && strongTag != file.entityTag
        if !file.ranges.ranges.isEmpty, changedTotal || changedTag {
            // The resource changed behind the URL: none of the file's bytes are its.
            downloadLog.warning("download: resource_changed gen=\(accepted.generation) total=\(total ?? -1)")
            start(at: offset, seekGeneration: accepted.seekGeneration, retrying: true, discardingFile: true)
            return false
        }
        current?.totalLength = total
        // A response that gives no total says nothing against the one already known.
        if let total { lastKnownTotalLength = total }
        if let total { effects.append(.makeRoom(bytes: total - accepted.base)) }
        current?.entityTag = strongTag
        recordIdentity(response)
        file.entityTag = file.entityTag ?? strongTag
        if finalURL == nil { finalURL = response.url }
        recordResponse(accepted, status: response.status, now: now)
        effects.append(.emit(.transaction(
            base: accepted.base, generation: accepted.generation, seekGeneration: accepted.seekGeneration, httpStatus: response.status
        )))
        current?.lastByteAt = now
        scheduleIdleCheck()
        effects.append(.wake)
        return true
    }

    private static func statusFailure(_ status: Int, _ contentRange: String?) -> StreamFailure {
        StreamFailure(.http(status: status), detail: "status=\(status) content-range=\(contentRange ?? "-")")
    }

    /// A new generation is a new response's, so the previous one's identity never shows under it.
    mutating func nextGeneration() {
        generation += 1
        responseEntityTag = nil
        responseLastModified = nil
    }

    /// An accepted response whose body starts the generation's bytes: the identity the snapshot gives.
    private mutating func recordIdentity(_ response: Response) {
        responseEntityTag = response.entityTag
        responseLastModified = response.lastModified
    }

    /// An accepted response to `tx`'s current request: its latency, and the startup's first answer.
    private mutating func recordResponse(_ tx: Transaction, status: Int, now: TimeInterval) {
        responseLatency = now - tx.attemptStartedAt
        guard startup.firstResponseAt == nil else { return }
        startup.firstResponseAt = now
        startup.status = status
        startup.remembered = tx.remembered
    }
}
