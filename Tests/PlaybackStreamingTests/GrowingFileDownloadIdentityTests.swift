import Foundation
import PlaybackDecode
import Testing

@testable import PlaybackStreaming

/// The snapshot's `entityTag`/`lastModified` belong to its `transactionGeneration`: an app compares
/// them when the generation changes, so a new generation never shows the previous one's.
extension GrowingFileDownloadTests {

    private static let firstDate = "Wed, 21 Oct 2015 07:28:00 GMT"
    private static let secondDate = "Thu, 22 Oct 2015 07:28:00 GMT"

    /// Generation 1 answered as `"v1"` of a 100000-byte resource, 100 bytes read, dropped, and the
    /// decoder sought to `position`: the retry restarts there as generation 2, its request out.
    private static func restarted(at position: Int64) throws -> Harness {
        let h = Harness()
        h.read()
        h.respond(206, range: "bytes 0-99999/100000", etag: "\"v1\"", lastModified: firstDate)
        h.body(100)
        h.read(100)
        h.end(error: -1005)
        try h.machine.seek(to: position)
        h.clock.advance(by: 0.1)
        #expect(h.requests.last == h.request(2, from: position))
        return h
    }

    private static func expectIdentity(
        _ h: Harness, generation: Int, etag: String?, lastModified: String?,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let snapshot = h.machine.snapshot(fileURL: nil, now: h.now)
        #expect(snapshot.transactionGeneration == generation, sourceLocation: sourceLocation)
        #expect(snapshot.entityTag == etag, sourceLocation: sourceLocation)
        #expect(snapshot.lastModified == lastModified, sourceLocation: sourceLocation)
    }

    @Test("a restart's generation has no identity from its open until its response is accepted")
    func aRestartHasNoIdentityUntilItsResponse() throws {
        let h = try Self.restarted(at: 50000)
        Self.expectIdentity(h, generation: 2, etag: nil, lastModified: nil)

        #expect(h.respond(206, range: "bytes 50000-99999/100000", etag: "W/\"v2\"", lastModified: Self.secondDate))
        Self.expectIdentity(h, generation: 2, etag: "W/\"v2\"", lastModified: Self.secondDate)
    }

    @Test("a restart whose response is refused leaves its generation without identity")
    func aRefusedRestartHasNoIdentity() throws {
        let error = try Self.restarted(at: 50000)
        #expect(!error.respond(503, etag: "\"v2\"", lastModified: Self.secondDate))
        Self.expectIdentity(error, generation: 2, etag: nil, lastModified: nil)

        let page = try Self.restarted(at: 50000)
        #expect(!page.respond(206, range: "bytes 50000-99999/100000", etag: "\"v1\"", mimeType: "text/html"))
        Self.expectIdentity(page, generation: 2, etag: nil, lastModified: nil)

        let outOfRange = try Self.restarted(at: 50000)
        #expect(!outOfRange.respond(416, range: "bytes */40000", etag: "\"v2\""))
        Self.expectIdentity(outOfRange, generation: 2, etag: nil, lastModified: nil)

        // The range ignored bumps the generation inside the response; the page then refuses it.
        let ignored = try Self.restarted(at: 50000)
        #expect(!ignored.respond(200, length: 100000, etag: "\"v1\"", mimeType: "text/html"))
        Self.expectIdentity(ignored, generation: 3, etag: nil, lastModified: nil)
    }

    @Test("a restart answered 416 at the resource's end carries that response's identity")
    func aRestartOpenAtTheEndCarriesItsIdentity() throws {
        let h = try Self.restarted(at: 100000)
        #expect(!h.respond(416, range: "bytes */100000", etag: "W/\"v2\"", lastModified: Self.secondDate))
        #expect(h.machine.current?.isComplete == true, "the open at the end was accepted")
        Self.expectIdentity(h, generation: 2, etag: "W/\"v2\"", lastModified: Self.secondDate)
    }

    @Test("a restart whose total changed opens another generation, without identity until it is answered")
    func aChangedTotalRestartHasNoIdentityUntilAnswered() throws {
        let h = try Self.restarted(at: 50000)
        #expect(!h.respond(206, range: "bytes 50000-199999/200000", etag: "\"v2\"", lastModified: Self.secondDate))
        #expect(h.requests.last == h.request(3, from: 50000))
        Self.expectIdentity(h, generation: 3, etag: nil, lastModified: nil)

        #expect(h.respond(206, range: "bytes 50000-199999/200000", etag: "\"v2\"", lastModified: Self.secondDate))
        Self.expectIdentity(h, generation: 3, etag: "\"v2\"", lastModified: Self.secondDate)
    }

    /// A whole body from byte 0 is a new response's bytes, compared at the overlap; its base and
    /// frontier stand, so the generation does too.
    @Test("a resume answered with a whole body takes its identity; one answered 206 keeps the first")
    func aResumeTakesTheIdentityOnlyOfAWholeBody() {
        for (status, range) in [(200, nil), (206, "bytes 0-99999/100000")] {
            let h = Harness()
            h.read()
            h.respond(206, range: "bytes 0-99999/100000", etag: "\"v1\"", lastModified: Self.firstDate)
            h.body(100)
            h.read(100)
            h.end(error: -1005)
            h.clock.advance(by: 0.1)
            #expect(h.requests.last == h.request(2, from: 0, ifRange: "\"v1\""))

            #expect(h.respond(status, range: range, length: 100000, etag: "W/\"v2\"", lastModified: Self.secondDate))
            #expect(h.opens == 1, "no restart")
            if status == 200 {
                Self.expectIdentity(h, generation: 1, etag: "W/\"v2\"", lastModified: Self.secondDate)
            } else {
                Self.expectIdentity(h, generation: 1, etag: "\"v1\"", lastModified: Self.firstDate)
            }
        }
    }
}
