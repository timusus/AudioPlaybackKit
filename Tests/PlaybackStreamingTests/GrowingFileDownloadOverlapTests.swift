import Foundation
import Testing

@testable import PlaybackStreaming

/// **The overlap at a join (ADR-0016), driven event by event with no server**: every request that
/// joins bytes on disk asks for up to 64 KiB of them again, and the adapter compares those with the
/// file. A match writes on as before; a mismatch is a changed resource. A 1 MB resource throughout.
struct GrowingFileDownloadOverlapTests {

    static let range = "bytes 0-999999/1000000"

    /// A transaction at 0, 1000 bytes read and 200 000 on disk, then dropped and resumed.
    private func resumed(etag: String? = nil) -> Harness {
        let h = Harness()
        h.read()
        h.respond(206, range: Self.range, etag: etag)
        h.body(200_000)
        h.read(1000)
        h.end(error: -1005)
        h.clock.advance(by: 0.1)
        return h
    }

    @Test("a resume asks from 64 KiB before the frontier, compares those bytes, and writes only past it")
    func aResumeComparesTheOverlap() {
        let h = resumed()
        #expect(h.requests.last == h.request(2, from: 134_464))
        #expect(h.respond(206, range: "bytes 134464-999999/1000000"))
        #expect(h.machine.chunkParts(attempt: 2, count: 70_000) == [
            .init(range: 134_464..<200_000, compare: true),
            .init(range: 200_000..<204_464, compare: false),
        ])
        h.body(65_536)
        #expect(h.machine.current?.frontier == 200_000, "the overlap moved the frontier")
        h.body(4464)
        #expect(h.machine.current?.frontier == 204_464)
        #expect(h.machine.file.ranges.ranges == [0..<204_464])
        #expect(h.machine.generation == 1, "a matching overlap keeps the file")
        #expect(h.opens == 1)
        #expect(!h.log.contains(.retire(discardFile: true)))
    }

    @Test("an overlap that differs discards the file and restarts at the decoder's position")
    func aMismatchedOverlapRestarts() {
        let h = resumed()
        #expect(h.respond(206, range: "bytes 134464-999999/1000000"))
        h.body(65_536, overlapMatches: false)
        #expect(h.log.contains(.retire(discardFile: true)))
        #expect(h.requests.last == h.request(3, from: 1000))
        #expect(h.machine.generation == 2)
        #expect(h.opens == 2)
    }

    @Test("a weak ETag is no validator: no If-Range, a changed one keeps the file, and only the bytes decide")
    func aWeakETagNeverDecides() {
        let h = resumed(etag: "W/\"a\"")
        #expect(h.requests.last == h.request(2, from: 134_464), "a weak ETag was sent as If-Range")
        #expect(h.respond(206, range: "bytes 134464-999999/1000000", etag: "W/\"b\""), "a changed weak ETag refused the resume")
        h.body(65_536)
        #expect(h.machine.generation == 1)

        let changed = resumed(etag: "W/\"a\"")
        changed.respond(206, range: "bytes 134464-999999/1000000", etag: "W/\"a\"")
        changed.body(65_536, overlapMatches: false)
        #expect(changed.log.contains(.retire(discardFile: true)), "the same weak ETag over other bytes kept the file")
    }

    @Test("a 200 to a resume's If-Range is a changed resource: the file is discarded")
    func aRefusedIfRangeDiscards() {
        let h = resumed(etag: "\"v1\"")
        #expect(h.requests.last == h.request(2, from: 134_464, ifRange: "\"v1\""))
        #expect(!h.respond(200, length: 1_000_000, etag: "\"v2\""))
        #expect(h.log.contains(.retire(discardFile: true)))
        #expect(h.requests.last == h.request(3, from: 1000))
    }

    @Test("a hole's request runs 64 KiB into the range after it, and the file is promoted only once that is compared")
    func theFarSeamIsComparedBeforePromotion() throws {
        let h = Harness()
        try h.machine.seek(to: 600_000)
        h.read()
        h.respond(206, range: "bytes 600000-999999/1000000")
        h.body(400_000)
        h.end()

        try h.machine.seek(to: 0)
        h.read()
        #expect(h.requests.last == h.request(2, from: 0, end: 665_536))
        #expect(h.respond(206, range: "bytes 0-665535/1000000"))
        h.body(600_000)
        #expect(h.machine.current?.frontier == 600_000)
        #expect(!h.machine.file.isCached, "promoted before the far seam was compared")
        #expect(h.machine.chunkParts(attempt: 2, count: 65_536) == [.init(range: 600_000..<665_536, compare: true)])
        h.body(65_535)
        #expect(!h.machine.file.isCached)
        h.body(1)
        #expect(h.machine.file.isCached)
        #expect(h.log.filter { $0 == .promote }.count == 1)
    }

    @Test("a far seam that differs discards the file, however much of the hole was written")
    func aMismatchedFarSeamRestarts() throws {
        let h = Harness()
        try h.machine.seek(to: 600_000)
        h.read()
        h.respond(206, range: "bytes 600000-999999/1000000")
        h.body(400_000)
        h.end()

        try h.machine.seek(to: 0)
        h.read(1000)
        h.respond(206, range: "bytes 0-665535/1000000")
        h.body(600_000)
        h.body(65_536, overlapMatches: false)
        #expect(h.log.contains(.retire(discardFile: true)))
        #expect(!h.machine.file.isCached)
        #expect(h.requests.last == h.request(3, from: 0))
        #expect(h.machine.file.ranges.ranges.isEmpty)
    }

    @Test("a Content-Length counts from where the overlap starts, not from the join")
    func aContentLengthCountsFromTheOverlap() throws {
        let h = Harness()
        h.read()
        h.respond(206, range: "bytes 0-999999/*")
        h.body(200_000)
        try h.machine.seek(to: 500_000)
        h.read()
        try h.machine.seek(to: 200_000)
        h.read()
        #expect(h.requests.last == h.request(3, from: 134_464))
        #expect(h.respond(206, range: "bytes 134464-999999/*", length: 865_536))
        #expect(h.machine.totalLength == 1_000_000)
        h.body(65_536 + 800_000)
        #expect(h.machine.file.isCached)
    }

    @Test("a 200 to a hole's bounded request from byte 0 is a range ignored: covered bytes are compared, not overwritten")
    func aWholeBodyToABoundedRequestFromZeroComparesCoveredBytes() throws {
        let h = Harness()
        try h.machine.seek(to: 600_000)
        h.read()
        h.respond(206, range: "bytes 600000-999999/1000000")
        h.body(400_000)
        h.end()

        try h.machine.seek(to: 0)
        h.read()
        #expect(h.requests.last == h.request(2, from: 0, end: 665_536))
        #expect(h.respond(200, length: 1_000_000))
        #expect(h.machine.rangeIgnored)
        #expect(h.machine.generation == 3, "a new generation, as for any range ignored")
        #expect(h.machine.current?.end == nil)
        #expect(h.machine.chunkParts(attempt: 2, count: 100_000) == [.init(range: 0..<100_000, compare: false)])
    }

    @Test("a 200 to a request that joins the run at byte 0 compares that run and writes only past it")
    func aRangeIgnoredJoinComparesTheRunAtZero() throws {
        let h = Harness()
        h.read()
        h.respond(206, range: "bytes 0-999999/1000000")
        h.body(200_000)
        try h.machine.seek(to: 500_000)
        h.read()
        try h.machine.seek(to: 200_000)
        h.read()
        #expect(h.respond(200, length: 1_000_000))
        #expect(h.machine.chunkParts(attempt: 3, count: 210_000) == [
            .init(range: 0..<200_000, compare: true),
            .init(range: 200_000..<210_000, compare: false),
        ])
        h.body(200_000)
        #expect(h.machine.current?.frontier == 200_000)
        h.body(800_000)
        #expect(h.machine.file.isCached)

        let changed = Harness()
        changed.read()
        changed.respond(206, range: "bytes 0-999999/1000000")
        changed.body(200_000)
        try changed.machine.seek(to: 500_000)
        changed.read()
        try changed.machine.seek(to: 200_000)
        changed.read()
        changed.respond(200, length: 1_000_000)
        changed.body(65_536, overlapMatches: false)
        #expect(changed.log.contains(.retire(discardFile: true)))
        #expect(changed.machine.file.ranges.ranges.isEmpty)
    }

    @Test("a resume inside a hole keeps both seams: from the overlap before the frontier to the one past the hole")
    func aResumeInAHoleKeepsBothSeams() throws {
        let h = Harness()
        try h.machine.seek(to: 600_000)
        h.read()
        h.respond(206, range: "bytes 600000-999999/1000000")
        h.body(400_000)
        h.end()

        try h.machine.seek(to: 0)
        h.read()
        h.respond(206, range: "bytes 0-665535/1000000")
        h.body(200_000)
        h.end(error: -1005)
        h.clock.advance(by: 0.1)
        #expect(h.requests.last == h.request(3, from: 134_464, end: 665_536))
        #expect(h.respond(206, range: "bytes 134464-665535/1000000"))
        h.body(65_536 + 400_000 + 65_536)
        #expect(h.machine.file.isCached)
        #expect(h.machine.generation == 2)
    }
}
