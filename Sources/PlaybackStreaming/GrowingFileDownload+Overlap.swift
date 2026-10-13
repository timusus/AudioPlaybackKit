import Foundation

// MARK: - The overlap at a join

extension GrowingFileDownload {

    /// How far a request reaches into the bytes on disk on each side of a join, to compare them
    /// (ADR-0016): the probe budget's size. A host that inserts ads per request can keep the total,
    /// the range and every validator while the bytes change, so only the bytes can tell.
    static let overlapBytes: Int64 = 64 << 10

    /// A run of a body chunk, in resource offsets: written into the file, or compared with it.
    struct ChunkPart: Equatable {
        let range: Range<Int64>
        let compare: Bool
    }

    /// Where a request writing from `join` starts: up to ``overlapBytes`` back into the covered
    /// range that ends there, or `join` when none does.
    func overlapStart(before join: Int64) -> Int64 {
        guard join > 0, let run = file.ranges.run(containing: join - 1) else { return join }
        return max(run.lowerBound, join - Self.overlapBytes)
    }

    /// Where a request bounded at `end` stops: up to ``overlapBytes`` into the covered range that
    /// starts there.
    func overlapEnd(after end: Int64?) -> Int64? {
        guard let end, let run = file.ranges.run(containing: end) else { return nil }
        return min(run.upperBound, end + Self.overlapBytes)
    }

    /// The next `count` bytes of the request `attempt`'s body, in order: the overlaps compared,
    /// the rest written. Nil when that body is no longer wanted.
    func chunkParts(attempt: Int, count: Int) -> [ChunkPart]? {
        guard !cancelled, let tx = current, tx.attempt == attempt, !tx.ended else { return nil }
        let chunk = tx.bodyAt..<(tx.bodyAt + Int64(count))
        let writeAt = tx.base + tx.written
        let tail = tx.checkEnd.flatMap { checkEnd in tx.end.map { $0..<checkEnd } }
        // The body runs [bodyAt, writeAt) compared, then written, then the far overlap compared,
        // then (a host that sent more than asked) written. Past writeAt, any byte the file already
        // holds is compared too: a 200 that ignored the range re-sends covered runs after a hole.
        let runs = file.ranges.ranges.filter { $0.overlaps(chunk) }
        let cuts = ([writeAt, tail?.lowerBound, tail?.upperBound].compactMap { $0 }
            + runs.flatMap { [$0.lowerBound, $0.upperBound] })
            .filter { chunk.contains($0) && $0 > chunk.lowerBound }
        var parts: [ChunkPart] = []
        var start = chunk.lowerBound
        for cut in Set(cuts).sorted() + [chunk.upperBound] where cut > start {
            let compare = start < writeAt || tail?.contains(start) == true || runs.contains { $0.contains(start) }
            parts.append(ChunkPart(range: start..<cut, compare: compare))
            start = cut
        }
        return parts
    }
}
