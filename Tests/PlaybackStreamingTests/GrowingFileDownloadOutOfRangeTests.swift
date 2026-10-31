import Foundation
import PlaybackDecode
import Testing
@testable import PlaybackStreaming

/// A position past the resource's end fails the read at once, with no retry: media3's
/// `DefaultLoadErrorHandlingPolicy` treats `ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE` as fatal.
extension GrowingFileDownloadTests {

    private static func failsOutOfRangeOnce(_ h: Harness, _ action: GrowingFileDownload.ReadStep.Action) {
        guard case .fail(.failed(let failure)) = action else {
            Issue.record("\(action) is no failure")
            return
        }
        #expect(failure.category == .malformed, "\(failure)")
        #expect(failure.detail.hasPrefix("out_of_range"), "\(failure)")
        h.clock.advance(by: 60)
        #expect(h.requests.count == 1, "no retry")
    }

    @Test("a 416 past the end fails the read at once")
    func a416PastTheEndFailsAtOnce() throws {
        let h = Harness()
        try h.machine.seek(to: 5000)
        _ = h.read()
        #expect(!h.respond(416, range: "bytes */1000"))
        Self.failsOutOfRangeOnce(h, h.read())
    }

    @Test("a 206 clamped to a last byte before the position fails the read at once")
    func aClampedRangeBeforeThePositionFailsAtOnce() throws {
        let h = Harness()
        try h.machine.seek(to: 5000)
        _ = h.read()
        #expect(!h.respond(206, range: "bytes 999-999/1000", length: 1))
        Self.failsOutOfRangeOnce(h, h.read())
    }

    @Test("a range answered 200 by a body that ends before the position fails the read at once")
    func aWholeBodyShorterThanThePositionFailsAtOnce() throws {
        let h = Harness()
        try h.machine.seek(to: 5000)
        _ = h.read()
        #expect(h.respond(200, length: 1000))
        h.body(1000)
        h.end()
        Self.failsOutOfRangeOnce(h, h.read())
    }

    @Test("a range answered 200 by a body of no length that ends before the position fails the read at once")
    func aWholeBodyOfNoLengthShorterThanThePositionFailsAtOnce() throws {
        let h = Harness()
        try h.machine.seek(to: 5000)
        _ = h.read()
        #expect(h.respond(200))
        h.body(1000)
        h.end()
        Self.failsOutOfRangeOnce(h, h.read())
    }
}
