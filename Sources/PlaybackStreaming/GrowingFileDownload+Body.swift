import Foundation
import PlaybackDecode

// MARK: - The body's chunks and its end

extension GrowingFileDownload {

    /// A chunk of `count` bytes was placed as ``chunkParts(attempt:count:)`` said, or its write
    /// failed with `writeError`. `overlapMatches`: every compared part equals the file.
    /// - Parameter head: the file's first ``GrowingFileByteSource/sniffBytes``, for the media
    ///   sniff; nil when they cannot be read.
    mutating func chunkWritten(
        _ count: Int, attempt: Int, writeError: Int32? = nil, overlapMatches: Bool = true,
        now: TimeInterval, head: () -> [UInt8]?
    ) -> [Effect] {
        // Still this request's: across the write, an idle check may have ended it and a resume
        // gone out from the frontier this chunk would move, under the same transaction.
        guard let tx = current, tx.attempt == attempt, !tx.ended else { return [] }
        if let writeError {
            end(StreamFailure(.io, detail: "write failed errno=\(writeError)"), retryable: false, now: now)
            return takeEffects()
        }
        guard overlapMatches else {
            // ADR-0016: the bytes at the join are another version of the resource.
            downloadLog.warning("download: resource_changed gen=\(tx.generation) overlap at=\(tx.bodyAt)")
            start(at: offset, seekGeneration: tx.seekGeneration, retrying: true, discardingFile: true)
            return takeEffects()
        }
        // The overlap before the join moves no frontier.
        let placed = Int64(count) - min(Int64(count), max(0, tx.base + tx.written - tx.bodyAt))
        current?.bodyAt += Int64(count)
        current?.written += placed
        current?.lastByteAt = now
        current?.rateAtPause = nil
        if tx.sniffPending, tx.written + placed >= Int64(GrowingFileByteSource.sniffBytes) {
            guard let bytes = head(), Self.isMedia(mimeType: nil, head: bytes) == true else {
                end(Self.notAudio("body sniff"), retryable: tx.remembered, refused: true, now: now)
                return takeEffects()
            }
            current?.sniffPending = false
        }
        // Only the bytes this chunk made readable: a range dropped from the set is never re-added.
        if let frontier = current?.frontier { file.record(tx.frontier..<frontier) }
        promoteIfWhole()
        // Progress is the decoder's: a host that drops before the read position (a 200 from
        // byte 0, every time) spends its retries instead of looping.
        if let frontier = current?.frontier, frontier > offset { retry.reset() }
        if firstSampleAt == nil { firstSampleAt = now }
        samples.append((now, count))
        if now - lastDownloadEventAt >= GrowingFileByteSource.downloadEventSeconds, let frontier = current?.frontier {
            lastDownloadEventAt = now
            effects.append(.emit(.download(frontier: frontier, downloadBytesPerSecond: downloadBytesPerSecond(now: now), complete: false)))
        }
        pauseIfFarAhead(now: now)
        effects.append(.wake)
        return takeEffects()
    }

    /// A page served where audio should be: media3's `IO_INVALID_HTTP_CONTENT_TYPE`.
    static func notAudio(_ why: String) -> StreamFailure {
        StreamFailure(.unsupported, detail: "not audio: \(why)")
    }

    /// URL errors no retry fixes: a refused certificate (-1201...-1206), ATS refusing the scheme
    /// (-1022), a malformed or unsupported URL (-1000, -1002). Like media3, which never retries a
    /// `CleartextNotPermittedException`. -1200 is retried: a handshake reset on a flaky link
    /// (Wi-Fi to cellular) surfaces as it, and media3 retries generic SSL IOExceptions.
    private static func isPermanent(domain: String, code: Int) -> Bool {
        guard domain == NSURLErrorDomain else { return false }
        return (-1206 ... -1201).contains(code) || [-1022, -1000, -1002].contains(code)
    }

    /// The request `attempt` ended: its body is whole when `errorCode` is nil.
    mutating func completed(
        attempt: Int, errorDomain: String = NSURLErrorDomain, errorCode: Int?, now: TimeInterval
    ) -> [Effect] {
        guard !cancelled, let tx = current, tx.attempt == attempt, !tx.ended else { return [] }
        if let errorCode {
            let urlError = errorDomain == NSURLErrorDomain ? URLError(URLError.Code(rawValue: errorCode)) : nil
            end(
                StreamFailure(.network, detail: "error=\(errorCode)", urlError: urlError),
                retryable: !Self.isPermanent(domain: errorDomain, code: errorCode), now: now
            )
            return takeEffects()
        }
        if tx.sniffPending {
            end(Self.notAudio("body of \(tx.written) bytes"), retryable: tx.remembered, refused: true, now: now)
            return takeEffects()
        }
        let expectedEnd = min(tx.bodyEnd ?? .max, tx.totalLength ?? .max)
        if expectedEnd < .max, tx.frontier < expectedEnd {
            end(StreamFailure(.network, detail: "short body ended=\(tx.frontier) expected=\(expectedEnd)"), retryable: true, now: now)
            return takeEffects()
        }
        current?.ended = true
        current?.isComplete = true
        // A bounded body ends at its bound, which says nothing of the resource's end.
        let total = tx.totalLength ?? (tx.end == nil ? tx.frontier : nil)
        current?.totalLength = total
        if let total { lastKnownTotalLength = total }
        // A body that never stated its length may have been cut short, so it is never cached.
        if tx.totalLength != nil { promoteIfWhole() }
        downloadLog.info("download: complete gen=\(tx.generation) base=\(tx.base) frontier=\(tx.frontier)")
        let complete = total.map { tx.frontier >= $0 } ?? false
        effects.append(.emit(.download(frontier: tx.frontier, downloadBytesPerSecond: downloadBytesPerSecond(now: now), complete: complete)))
        effects.append(.wake)
        return takeEffects()
    }
}
