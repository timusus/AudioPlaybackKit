import Foundation
import Testing

@testable import PlaybackStreaming

/// **Redirect chains and pages, driven event by event with no server**: where a retry goes after a
/// chain crossed schemes, and a non-audio page answering from the chain's remembered end.
struct GrowingFileDownloadRedirectTests {

    static let signedEnd = URL(string: "https://cdn.example/signed/episode.mp3")!

    @Test("a chain that crosses schemes either way is remembered whole: the resume goes to the end, scheme included",
          arguments: [
            ("http://host.example/episode.mp3", "https://cdn.example/episode.mp3"),
            ("https://host.example/episode.mp3", "http://cdn.example/episode.mp3"),
          ])
    func aCrossProtocolChainEndIsResumedAt(from: String, to: String) {
        let start = URL(string: from)!
        let end = URL(string: to)!
        let h = Harness()
        h.machine = GrowingFileDownload(url: start, readAhead: nil)
        h.read()
        #expect(h.requests == [h.request(1, from: 0, url: start)])
        #expect(h.respond(206, range: "bytes 0-9999/10000", url: end))
        h.body(3000)
        h.end(error: -1005)
        h.clock.advance(by: 0.1)

        #expect(h.requests.last == h.request(2, from: 0, url: end))
        #expect(h.respond(206, range: "bytes 0-9999/10000", url: end))
        #expect(h.transactionEvents == 1)
    }

    @Test("a page from the remembered end of a resume forgets the end and retries at the requested URL")
    func aPageOnAResumeIsRetriedAtTheRequestedURL() {
        let h = Harness()
        h.read()
        h.respond(206, range: "bytes 0-9999/10000", url: Self.signedEnd)
        h.body(2000)
        h.end(error: -1005)
        h.clock.advance(by: 0.1)
        #expect(h.requests.last == h.request(2, from: 0, url: Self.signedEnd))

        #expect(h.respond(206, range: "bytes 0-9999/10000", mimeType: "text/html") == false)
        #expect(h.machine.finalURL == nil, "the signed hop may have expired")
        #expect(h.machine.retry.attempts == 2)
        h.clock.advance(by: 1)
        #expect(h.requests.last == h.request(3, from: 0))
        #expect(h.respond(206, range: "bytes 0-9999/10000"))
        h.body(10_000)
        h.end()
        #expect(h.machine.file.isCached)
    }

    @Test("a page from the remembered end of a seek's new transaction is retried at the requested URL")
    func aPageOnASeekIsRetriedAtTheRequestedURL() throws {
        let h = Harness()
        h.read()
        h.respond(206, range: "bytes 0-9999/10000", url: Self.signedEnd)
        h.body(2000)
        try h.machine.seek(to: 8000)
        h.read()
        #expect(h.requests.last == h.request(2, from: 8000, url: Self.signedEnd))

        #expect(h.respond(206, range: "bytes 8000-9999/10000", mimeType: "text/html") == false)
        #expect(h.machine.finalURL == nil)
        h.clock.advance(by: 1)
        #expect(h.requests.last == h.request(3, from: 8000))
        #expect(h.respond(206, range: "bytes 8000-9999/10000"))
    }

    @Test("a page from the first request, with nothing remembered, fails the read instead of retrying")
    func aPageOnTheFirstRequestFails() {
        let h = Harness()
        h.read()
        #expect(h.respond(200, length: 500, mimeType: "text/html") == false)
        #expect(!h.log.contains { if case .schedule(.retry, _) = $0 { true } else { false } })
        #expect(h.read() == .fail(.transport("not audio: content-type=text/html")))
    }

    @Test("a page on the resume's retry, now from the requested URL, fails the read: the retry is not repeated")
    func aSecondPageOnAResumeFails() {
        let h = Harness()
        h.read()
        h.respond(206, range: "bytes 0-9999/10000")
        h.body(2000)
        h.end(error: -1005)
        h.clock.advance(by: 1)
        h.respond(206, range: "bytes 0-9999/10000", mimeType: "text/html")
        h.clock.advance(by: 1)
        #expect(h.requests.count == 3)
        #expect(h.respond(206, range: "bytes 0-9999/10000", mimeType: "text/html") == false)

        h.clock.advance(by: 10)
        #expect(h.requests.count == 3, "no fourth request")
        #expect(h.read() == .fail(.transport("not audio: content-type=text/html")))
    }
}
