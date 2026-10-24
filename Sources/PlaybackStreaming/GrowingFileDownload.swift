import Foundation
import OSLog
import PlaybackDecode

let downloadLog = Logger(subsystem: "com.simplecityapps.AudioPlaybackKit", category: "download")

/// **The growing-file source's transaction lifecycle, as one state machine**: ADR-0004's single
/// recovery layer as one module.
///
/// Events go in: the decoder's reads and seeks, a response, body bytes, a task's end, a timer the
/// machine asked for, a new network path. ``Effect``s come out, for the adapter
/// (``GrowingFileByteSource``) to carry out in order: open a file, send a request, cancel a task,
/// schedule a timer, wake a parked read, hand an event out. A read gets a ``ReadStep``: serve from
/// the file, park, end, or fail. Every rule of the source lives here: the read rule (``ReadRule``),
/// the retry budget (``Retry``), resume or restart, the read-ahead pause, the redirect chain's
/// remembered end, the seek generation a transaction carries, the measured rate.
///
/// No lock, task, file or clock: times come in with each event, and every transition is driven by
/// a test with literal numbers. The adapter holds the one lock around every call.
struct GrowingFileDownload {

    // MARK: - State

    /// How far behind the reader a range of a resource with no known total is kept (ADR-0014): an
    /// hour at 128 kbps, under the store's free-space headroom.
    static let unknownLengthWindowBytes: Int64 = 64 << 20

    let url: URL
    var current: Transaction?
    var file: SessionFile
    /// The decoder's read position.
    private(set) var offset: Int64 = 0
    var generation = 0
    /// Reads that have parked at the frontier so far.
    private(set) var parks = 0
    /// When the current read first parked; cleared by ``endRead()`` when the read returns or throws,
    /// so a wake that re-parks (a retry, a restart) keeps the original time.
    private(set) var readWaitingSince: TimeInterval?
    /// Set around the decoder's `open()`; see ``ReadRule``.
    var isProbing = false
    var startup = GrowingFileByteSource.Startup()
    var retry = Retry()
    private(set) var cancelled = false
    private var interrupted = false
    /// A seek announced by ``willSeek(generation:)`` that no read has answered yet. The read that
    /// answers it claims it, once: it opens the transaction that carries it, or finds its bytes
    /// already in the file and reports ``GrowingFileEvent/seekLanded(seekGeneration:)``. `sought`
    /// says the decoder moved the read position for it; one it answered from its own buffer never
    /// did, and the read after it is no seek's, so it tags nothing.
    private var unclaimedSeek: (generation: Int, sought: Bool)?
    /// A parked read's recheck is scheduled; one at a time however often the read wakes.
    var recheckPending = false
    /// Why the current transaction cannot deliver more; a read at its frontier throws it.
    var failure: StreamFailure?
    /// The failure a read threw, until the next ``seek(to:)`` or ``willSeek(generation:)``: a read
    /// after the throw throws it again instead of opening a transaction nobody asked for.
    private var stickyFailure: StreamFailure?
    /// The resource's length as the last accepted response gave it: what ``totalLength`` and the
    /// snapshot answer once a failed read has dropped the transaction that knew it.
    var lastKnownTotalLength: Int64?
    /// The raw validators, weak tags included, of the response this generation's body started
    /// from: identity for the snapshot, unlike ``SessionFile/entityTag``, which gates `If-Range`.
    /// Nil from the generation's bump until its response is accepted (``nextGeneration()``).
    var responseEntityTag: String?
    var responseLastModified: String?
    /// The host answered a ranged request with `200`: every later transaction starts at byte 0.
    var rangeIgnored = false
    /// The end of the redirect chain, from the first response; later requests go straight there
    /// until one there is refused or unanswered.
    var finalURL: URL?
    /// The chain's end was just forgotten: the next request walks the chain from `url` with the
    /// generous wait, even as a retry. Once; the request it goes with clears it.
    var chainEndForgotten = false
    /// The last accepted response's time from its request going out: what a new request costs,
    /// which ``ReadRule`` weighs a seek's wait against.
    var responseLatency: TimeInterval?
    var samples: [(at: TimeInterval, bytes: Int)] = []
    var firstSampleAt: TimeInterval?
    var lastDownloadEventAt: TimeInterval = -.infinity
    /// When an event last came in: a gap since then longer than any timer was a suspension (``ran(now:)``).
    var lastRanAt: TimeInterval?
    private var transactionsOpened = 0
    var attemptsSent = 0
    /// An ``Effect/openFile`` is out: what the transaction it opens is.
    private var pendingOpen: (base: Int64, end: Int64?, seekGeneration: Int?, retrying: Bool)?
    /// The last read step opened a transaction because there was none; if it is still missing the
    /// read fails instead of asking again.
    private var readOpened = false
    var effects: [Effect] = []
    /// How far the frontier may run ahead of the decoder while the path is expensive; nil is no cap.
    private let readAheadSetting: GrowingFileReadAhead?
    /// The probed stream's duration as the host reported it; the bitrate follows once the length is known.
    var probedDuration: TimeInterval?
    /// The cap in bytes: the seconds form resolves to it with the stream's bitrate.
    var readAhead: Int64? {
        var bitsPerSecond: Double?
        if let probedDuration, let total = totalLength, total > 0 { bitsPerSecond = Double(total) * 8 / probedDuration }
        return readAheadSetting?.limit(bitsPerSecond: bitsPerSecond)
    }
    /// The network path is expensive or constrained: the read-ahead cap applies.
    var pathIsExpensive = false

    init(url: URL, readAhead: GrowingFileReadAhead? = nil, unknownLengthWindow: Int64 = Self.unknownLengthWindowBytes) {
        self.url = url
        self.readAheadSetting = readAhead
        self.file = SessionFile(unknownLengthWindow: unknownLengthWindow)
    }

    // MARK: - Published state

    var totalLength: Int64? { current?.totalLength ?? lastKnownTotalLength }

    /// `base`/`frontier` are the covered run the reader is in, else the current transaction's (ADR-0014).
    mutating func snapshot(fileURL: URL?, now: TimeInterval) -> GrowingFileSnapshot {
        let run = file.ranges.run(containing: offset)
        // A transaction whose file is gone has nothing readable.
        let tx = file.exists ? current : nil
        return GrowingFileSnapshot(
            base: run?.lowerBound ?? tx?.base ?? offset,
            frontier: run?.upperBound ?? tx?.frontier ?? offset,
            totalLength: totalLength,
            // Nothing up to the end is owed to the reader, whichever transactions wrote it.
            isComplete: totalLength.map { (run?.upperBound ?? offset) >= $0 } ?? false,
            fileURL: fileURL,
            transactionGeneration: generation,
            seekGeneration: current?.seekGeneration,
            downloadBytesPerSecond: downloadBytesPerSecond(now: now),
            readWaitingSince: readWaitingSince,
            entityTag: responseEntityTag,
            lastModified: responseLastModified
        )
    }

    /// Body bytes per second over the last ``GrowingFileByteSource/throughputWindowSeconds``.
    mutating func downloadBytesPerSecond(now: TimeInterval) -> Double? {
        guard let firstSampleAt else { return nil }
        samples.removeAll { now - $0.at > GrowingFileByteSource.throughputWindowSeconds }
        let span = min(GrowingFileByteSource.throughputWindowSeconds, max(0.25, now - firstSampleAt))
        return Double(samples.reduce(0) { $0 + $1.bytes }) / span
    }

    // MARK: - The decoder's side

    /// The player's seek of `generation` is about to be issued; nil drops a claim no read has taken.
    mutating func willSeek(generation: Int?) {
        unclaimedSeek = generation.map { ($0, false) }
        stickyFailure = nil
    }

    mutating func seek(to newOffset: Int64) throws {
        if cancelled { throw StreamByteReaderError.cancelled }
        if interrupted { throw StreamByteReaderError.interrupted }
        guard newOffset >= 0 else { throw StreamByteReaderError.unseekable }
        // Past a known total nothing can arrive (an estimated transcode length may overpromise);
        // the total itself is end of stream.
        if let total = totalLength, newOffset > total { throw StreamByteReaderError.unseekable }
        // A body of no length whose range was answered 200 (a live transcode) only arrives in order:
        // media3's SeekMap.Unseekable. Waiting for it would fail later as a transport error.
        if let tx = current, tx.answered, tx.totalLength == nil, !tx.rangeHonoured, newOffset > tx.frontier {
            throw StreamByteReaderError.unseekable
        }
        offset = newOffset
        unclaimedSeek?.sought = true
        stickyFailure = nil
    }

    /// End of the run of the file holding the decoder's position. Nil when a seek ahead could not
    /// fetch sooner than reading on: the host ignores ranges, or `seek` would refuse it.
    var fetchedEnd: Int64? {
        if rangeIgnored { return nil }
        if let tx = current, tx.answered, tx.totalLength == nil, !tx.rangeHonoured { return nil }
        return file.ranges.run(containing: offset)?.upperBound ?? offset
    }

    mutating func interrupt() -> [Effect] {
        interrupted = true
        return [.wake]
    }

    mutating func clearInterrupt() {
        interrupted = false
    }

    /// A read of up to `maxLength` bytes at the decoder's position. `isRecheck` re-runs the
    /// decision of a read that just parked, so it is not a new park.
    mutating func read(maxLength: Int, now: TimeInterval, isRecheck: Bool = false) -> ReadStep {
        ran(now: now)
        let opened = readOpened
        readOpened = false
        if cancelled { return step(.fail(.cancelled)) }
        if interrupted { return step(.fail(.interrupted)) }
        for range in file.dropBehind(offset, totalLength: totalLength) { effects.append(.punchHole(range)) }
        let run = file.ranges.run(containing: offset)
        guard current != nil || run != nil else {
            if opened { return step(.fail(.failed(failure ?? StreamFailure(.internal, detail: "no transaction")))) }
            if let reason = stickyFailure { return step(.fail(.failed(reason))) }
            start(at: offset, seekGeneration: claimSeek())
            readOpened = true
            return step(.again)
        }
        let tx = current
        // The end, learned after the seek (a host that ignored its range), is before the read:
        // media3's DefaultHttpDataSource.skipFully fails that as out of range.
        if let total = tx?.totalLength, offset > total {
            return reportFailure(StreamFailure(.malformed, detail: "out_of_range at=\(offset) total=\(total)"))
        }
        // A failure that deleted the file (a page, a full disk) took its frontier with it, so the
        // decoder's next read is no seek ahead: it gets the failure, unless the total length says
        // nothing is owed there (ADR-0004: the layer fails what it still owes, not a finished stream).
        if let tx, let reason = failure, !file.exists, tx.totalLength.map({ offset < $0 }) ?? true {
            return reportFailure(reason)
        }
        // Only a transaction that will bring bytes up to the read is waited for.
        let frontier = tx.flatMap { tx in
            !tx.isComplete && offset >= tx.frontier && offset < (tx.end ?? .max) ? tx.frontier : nil
        }
        let action = ReadRule.action(
            position: offset, isCovered: run != nil, frontier: frontier, totalLength: tx?.totalLength,
            isProbing: isProbing, rangeIgnored: rangeIgnored,
            downloadBytesPerSecond: tx?.rateAtPause ?? downloadBytesPerSecond(now: now),
            responseLatency: responseLatency
        )
        if let tx, tx.paused, action == .serve || action == .wait, let readAhead,
           offset >= tx.base, tx.frontier - offset <= readAhead / 2 {
            resume(now: now)
        }
        switch action {
        case .serve:
            let count = Int(min(Int64(maxLength), (run?.upperBound ?? offset) - offset))
            return step(.serve(fileOffset: offset, count: count, landed: landSeek()))
        case .endOfStream:
            return step(.endOfStream(landed: landSeek()))
        case .restart:
            retry.reset()
            start(at: offset, seekGeneration: claimSeek())
            return step(.again)
        case .wait:
            if let reason = failure { return reportFailure(reason) }
            if !isRecheck { parks += 1 }
            readWaitingSince = readWaitingSince ?? now
            if !recheckPending {
                recheckPending = true
                effects.append(.schedule(.recheck, after: GrowingFileByteSource.recheckSeconds))
            }
            return step(.park)
        }
    }

    /// The read that was parked has been served, ended or failed.
    mutating func endRead() {
        readWaitingSince = nil
    }

    /// The failed transaction goes with the error. The error stays until a seek (Play once the
    /// player shows it seeks to where it stopped), whose read opens a fresh one there with a fresh
    /// budget; the total length stays known.
    private mutating func reportFailure(_ reason: StreamFailure) -> ReadStep {
        // The file's bytes stay for a seek to read; a file with none is not kept.
        retireCurrent(discardingFile: file.ranges.ranges.isEmpty)
        current = nil
        effects.append(.release)
        failure = nil
        stickyFailure = reason
        retry.reset()
        return step(.fail(.failed(reason)))
    }

    /// A served read copied `count` bytes.
    mutating func advance(by count: Int) {
        offset += Int64(count)
    }

    /// Ends the download: a new load or stop. Logs what was fetched and never read.
    mutating func cancel() -> [Effect] {
        guard !cancelled else { return [] }
        cancelled = true
        if let tx = current {
            let wasted = max(0, tx.frontier - max(offset, tx.base))
            let share = tx.totalLength.map { $0 > 0 ? Double(wasted) / Double($0) : 0 } ?? 0
            downloadLog.info("download: cancel bytes_wasted=\(wasted) share=\(share, format: .fixed(precision: 3))")
        }
        // The session's file goes with it even when no transaction is left.
        retireCurrent(discardingFile: true)
        effects.append(.wake)
        return takeEffects()
    }

    /// The complete file leaves the cache: whether there was one, which the adapter deletes.
    mutating func dropCachedFile() -> Bool {
        guard file.isCached, file.exists else { return false }
        file.deleted()
        return true
    }

    // MARK: - Transactions

    /// The answer to an ``Effect/openFile``: the new transaction's request goes out, or, without a
    /// file, there is no transaction and `failure` says why.
    mutating func opened(fileReady: Bool, now: TimeInterval) -> [Effect] {
        ran(now: now)
        guard let open = pendingOpen else { return [] }
        pendingOpen = nil
        guard fileReady else {
            failure = StreamFailure(.io, detail: "cannot open a partial")
            return takeEffects() + [.wake]
        }
        file.exists = true
        nextGeneration()
        transactionsOpened += 1
        current = Transaction(
            id: transactionsOpened, generation: generation, seekGeneration: open.seekGeneration,
            remembered: finalURL != nil, base: open.base, end: open.end, checkEnd: overlapEnd(after: open.end)
        )
        if startup.requestIssuedAt == nil { startup.requestIssuedAt = now }
        send(from: overlapStart(before: open.base), ifRange: nil, retrying: open.retrying, now: now)
        let opened = generation, host = url.host ?? "?"
        downloadLog.info("download: open gen=\(opened) base=\(open.base) host=\(host, privacy: .public)")
        return takeEffects() + [.wake]
    }

    /// Promotes the file once `[0, total)` is on disk, whichever transactions wrote it (ADR-0014).
    /// A body with more to send then (the whole file answering a bounded request) could only
    /// rewrite bytes already there, so it ends.
    mutating func promoteIfWhole() {
        guard file.isWhole(totalLength: totalLength) else { return }
        // Not before the far seam is compared: a mismatch there discards the file.
        if let tx = current, !tx.ended, let checkEnd = tx.checkEnd, tx.frontier < checkEnd { return }
        // Nor while a whole body (a range ignored) still has covered runs ahead to compare.
        if let tx = current, !tx.ended, tx.end == nil, let total = tx.totalLength, tx.bodyAt < total { return }
        effects.append(.promote)
        guard let tx = current, !tx.ended, tx.frontier < min(tx.end ?? .max, tx.totalLength ?? .max) else { return }
        current?.ended = true
        current?.isComplete = true
        effects.append(.cancelTask)
    }

    /// The complete file is the cache's now.
    mutating func promoted() {
        file.isCached = true
        if let tx = current { downloadLog.info("download: cached gen=\(tx.generation)") }
    }

    /// A hop of the redirect chain, before the first accepted response.
    mutating func redirected(toHost host: String?) {
        if startup.firstResponseAt == nil, let host { startup.hosts.append(host) }
    }

    /// Retires the current transaction and asks for one at the first hole from `start`, up to the
    /// next covered range (ADR-0014; media3's `CacheDataSource` bounds a network read the same way),
    /// or for the whole body once the host ignores ranges.
    /// - Parameters:
    ///   - seekGeneration: the seek this transaction answers, nil when none asked for it.
    ///   - retrying: a retry's restart, whose request waits the shorter time (``target(retrying:)``).
    ///   - discardingFile: the session's file is not this resource's any more.
    mutating func start(at start: Int64, seekGeneration: Int?, retrying: Bool = false, discardingFile: Bool = false) {
        if current != nil { retireCurrent(discardingFile: discardingFile) }
        current = nil
        failure = nil
        let from = rangeIgnored ? 0 : file.ranges.firstHole(atOrAfter: start)
        let end = rangeIgnored ? nil : file.ranges.nextCoveredStart(after: from)
        pendingOpen = (from, end, seekGeneration, retrying)
        effects.append(.openFile)
    }

    /// The seek waiting for a read, taken by the read that answers it: its generation when the
    /// read is at the position that seek moved to, the tag for a transaction this read opens.
    private mutating func claimSeek() -> Int? {
        defer { unclaimedSeek = nil }
        guard let claim = unclaimedSeek, claim.sought else { return nil }
        return claim.generation
    }

    /// The seek waiting for a read, answered from the file: whether or not the decoder moved for
    /// it, no transaction will carry it.
    private mutating func landSeek() -> Int? {
        defer { unclaimedSeek = nil }
        return unclaimedSeek?.generation
    }

    /// A position past the resource's end, which no retry brings (media3's
    /// `ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE` is fatal). The file's bytes, all before that end, stay.
    mutating func failOutOfRange(_ reason: String) {
        current?.ended = true
        effects.append(.cancelTask)
        downloadLog.error("download: failed out_of_range \(reason, privacy: .public)")
        failure = StreamFailure(.malformed, detail: "out_of_range \(reason)")
        effects.append(.wake)
    }

    /// Cancels the task; its bytes stay in the session's file. `discardingFile` deletes the file too,
    /// unless it is the cache's now.
    mutating func retireCurrent(discardingFile: Bool = false) {
        current?.ended = true
        let discard = discardingFile && file.exists && !file.isCached
        if discard { file.deleted() }
        effects.append(.retire(discardFile: discard))
    }

    mutating func step(_ action: ReadStep.Action) -> ReadStep {
        ReadStep(effects: takeEffects(), action: action)
    }

    mutating func takeEffects() -> [Effect] {
        defer { effects = [] }
        return effects
    }
}
