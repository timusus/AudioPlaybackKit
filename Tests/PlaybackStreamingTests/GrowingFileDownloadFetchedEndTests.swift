import Foundation
import Testing
@testable import PlaybackStreaming

/// Where the fetched bytes end, which the decoder seeks past rather than reads forward to.
extension GrowingFileDownloadTests {

    @Test("the fetched bytes end at the frontier of the run holding the position, or at the position")
    func theFetchedBytesEndAtTheRunHoldingThePosition() throws {
        let h = Harness()
        _ = h.read()
        #expect(h.respond(206, range: "bytes 0-9999/10000"))
        h.body(4000)
        #expect(h.machine.fetchedEnd == 4000)
        #expect(h.read(1000) == .serve(fileOffset: 0, count: 1000, landed: nil))
        #expect(h.machine.fetchedEnd == 4000)
        try h.machine.seek(to: 6000)
        #expect(h.machine.fetchedEnd == 6000, "nothing is held past an unfetched position")
    }

    @Test("a host that ignores ranges has no fetched end: a seek ahead could not fetch sooner")
    func aRangeIgnoringHostHasNoFetchedEnd() throws {
        let h = Harness()
        try h.machine.seek(to: 5000)
        _ = h.read()
        #expect(h.respond(200, length: 10000))
        h.body(1000)
        #expect(h.machine.fetchedEnd == nil)
    }

    @Test("a body of no length answered 200 has no fetched end: the source refuses a seek past it")
    func aRangeIgnoringBodyOfNoLengthHasNoFetchedEnd() {
        let h = Harness()
        _ = h.read()
        #expect(h.respond(200))
        h.body(1000)
        #expect(h.machine.fetchedEnd == nil)
    }
}
