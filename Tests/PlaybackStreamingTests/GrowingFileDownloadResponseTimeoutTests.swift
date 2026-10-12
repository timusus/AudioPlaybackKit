import Foundation
import Testing

@testable import PlaybackStreaming

/// The wait for a request's response is the machine's, on its clock: it cancels the task itself and
/// hands the failure to ``GrowingFileDownload/Retry``. Times are literal seconds from 1000.
extension GrowingFileDownloadTests {

    @Test("a first request with no response is ended at exactly 20 s, as an unanswered failure")
    func theResponseTimeoutFiresAtTheLimit() {
        let h = Harness()
        #expect(h.read() == .park)
        h.clock.advance(by: 19.75)
        #expect(!h.log.contains(.cancelTask))

        h.clock.advance(by: 0.25)
        #expect(h.log.contains(.cancelTask))
        #expect(h.machine.retry.attempts == 0, "nothing answered: no attempt spent")
        #expect(h.machine.retry.linkDownSince == 1000, "the link went quiet when the request went out")
        #expect(h.log.contains(.schedule(.retry(transaction: 1), after: 0.1)))
    }

    @Test("a response clears the wait: a body still arriving past 20 s is not ended")
    func theResponseTimeoutDoesNotFireOnceAnswered() {
        let h = Harness()
        h.read()
        h.clock.advance(by: 10)
        #expect(h.respond(206, range: "bytes 0-9999/10000"))
        h.clock.advance(by: 5)
        h.body(1000)
        h.clock.advance(by: 5)
        h.body(1000)
        h.clock.advance(by: 1)
        #expect(!h.log.contains(.cancelTask))
        #expect(h.requests.count == 1)
        #expect(h.machine.retry.failuresInRow == 0)
    }

    @Test("after the timeout, retries follow the backoff with the retry's wait, until the link window ends")
    func theResponseTimeoutRetriesWithTheBackoff() {
        let h = Harness()
        h.read()
        h.clock.advance(by: 20)
        h.clock.advance(by: 0.1)
        #expect(h.requests.last == h.request(2, from: 0))
        #expect(h.log.contains(.schedule(.response(attempt: 2), after: 8)))

        h.clock.advance(by: 8)
        #expect(h.log.contains(.schedule(.retry(transaction: 2), after: 0.2)), "the backoff doubles")
        h.clock.advance(by: 0.2)
        #expect(h.requests.last == h.request(3, from: 0))
        #expect(h.machine.retry.attempts == 0)

        // The third wait is cut at the window's end, 30 s after the first request went out.
        h.clock.advance(by: 1.5)
        #expect(h.read() == .park)
        h.clock.advance(by: 0.25)
        #expect(h.requests.count == 3)
        #expect(h.read() == .fail(.transport("no_response_s=1")))
    }
}
