import Foundation
import PlaybackDecode
import Testing

@testable import PlaybackStreaming

/// Time the process spent suspended is not time the link was down: whatever event comes first on
/// resume, the link window and the attempt's wait resume where they stood. Times are literal
/// seconds from 1000.
extension GrowingFileDownloadTests {

    @Test("an unanswered request that completes after a 2 h suspension is retried, not failed")
    func aSuspensionIsNotLinkDownTime() {
        let h = Harness()
        #expect(h.read() == .park)
        h.clock.advance(by: 1)
        h.clock.suspend(for: 7200)
        h.end(error: -1001)

        #expect(h.log.contains(.schedule(.retry(transaction: 1), after: 0.1)))
        #expect(h.machine.retry.linkDownSince == 8200, "the second awake before the suspension is spent, the 2 h are not")
        h.clock.advance(by: 0.1)
        #expect(h.requests.last == h.request(2, from: 0))
        #expect(h.read() == .park)
    }

    @Test("suspended in the backoff after a quiet failure, the overdue retry gets its full wait and the load recovers")
    func aSuspensionInTheBackoffKeepsTheWindow() {
        let h = Harness()
        h.read()
        h.end(error: -1009)
        #expect(h.log.contains(.schedule(.retry(transaction: 1), after: 0.1)))
        h.clock.suspend(for: 7200)
        h.clock.advance(by: 0)

        #expect(h.requests.last == h.request(2, from: 0))
        #expect(h.log.contains(.schedule(.response(attempt: 2), after: 8)), "the window was not spent while suspended")
        #expect(h.respond(206, range: "bytes 0-99/100"))
        h.body(100)
        #expect(h.read() == .serve(fileOffset: 0, count: 100, landed: nil))
    }

    @Test("the overdue response timer fires on resume before the late completion: a retry, not a failure")
    func anOverdueResponseTimerIsRetried() {
        let h = Harness()
        h.read()
        h.clock.suspend(for: 7200)
        h.clock.advance(by: 0)

        #expect(h.log.contains(.schedule(.retry(transaction: 1), after: 0.1)))
        #expect(h.machine.retry.linkDownSince == 8200)
        h.end(error: -1001)
        #expect(h.machine.retry.failuresInRow == 1, "the late completion of the ended attempt changes nothing")
        h.clock.advance(by: 0.1)
        #expect(h.requests.last == h.request(2, from: 0))
        #expect(h.respond(206, range: "bytes 0-99/100"))
    }

    @Test("a 503 opens no link window; a suspension after it, then a quiet outage, still gets the full window")
    func aRefusalIsNoSuspension() {
        let h = Harness()
        h.read()
        #expect(!h.respond(503))
        #expect(h.machine.retry.attempts == 1)
        #expect(h.machine.retry.linkDownSince == nil, "the host answered")

        h.clock.advance(by: 0.1)
        #expect(h.requests.last == h.request(2, from: 0))
        h.clock.suspend(for: 100)
        h.clock.advance(by: 0)
        #expect(h.machine.failure == nil, "the overdue wait is retried, not failed")
        #expect(h.machine.retry.linkDownSince.map { $0 > 1100 } == true, "the window starts after the suspension")

        let offline = offline(h, upTo: 60)
        #expect(offline > 28 && offline < 31, "failed \(offline) s into the outage")
        #expect(h.machine.failure != nil)
    }

    @Test("a 30 s outage with timers on time still fails")
    func aRealOutageStillFails() {
        let h = Harness()
        h.read()
        h.clock.advance(by: 20)
        h.clock.advance(by: 0.1)
        h.clock.advance(by: 8)
        h.clock.advance(by: 0.2)
        h.clock.advance(by: 1.75)
        #expect(h.read() == .fail(.failed(StreamFailure(.network, detail: "no_response_s=1"))))
    }

    @Test("a suspension while the body flowed resumes from the frontier")
    func aSuspensionMidBodyResumesFromTheFrontier() {
        let h = Harness()
        h.read()
        h.respond(206, range: "bytes 0-99999/100000")
        h.body(100)
        h.read(100)
        h.clock.advance(by: GrowingFileByteSource.idleTimeoutSeconds)
        h.clock.advance(by: 0.1)
        #expect(h.requests.last == h.request(2, from: 0), "the quiet body is retried from the frontier, overlapping back")
        h.clock.suspend(for: 7200)
        h.clock.advance(by: 0)

        #expect(h.machine.failure == nil, "the suspension is not link-down time")
        h.clock.advance(by: 0.2)
        #expect(h.requests.last == h.request(3, from: 0), "the same resume again, no gap")
        #expect(h.respond(206, range: "bytes 0-99999/100000"))
        h.body(200)
        #expect(h.read(100) == .serve(fileOffset: 100, count: 100, landed: nil), "no gap or duplicate bytes")
    }

    @Test("after a 1 h read-ahead pause, a resume that fails at once gets the link window from it, no more and no less")
    func aLongPauseThenAnOutageGetsANormalWindow() {
        let h = Harness(readAhead: 100_000)
        h.pathCost(isExpensive: true)
        h.read()
        h.clock.advance(by: 0.5)
        h.respond(206, range: "bytes 0-999999/1000000", etag: "\"v1\"")
        h.body(100_000)
        #expect(h.machine.current?.paused == true)
        h.clock.advance(by: 3600)

        h.read(50_000)
        h.read(1)
        #expect(h.requests.count == 2, "the read resumed the transaction")
        let offline = offline(h, upTo: 60)
        #expect(offline > 28 && offline < 31, "failed \(offline) s into the outage")
    }

    @Test("repeated suspensions while offline each keep the window where it stood: the load still fails")
    func repeatedSuspensionsStayBounded() {
        let h = Harness()
        h.read()
        h.end(error: -1009)
        var awake = 0.0
        for _ in 0..<3 {
            awake += offline(h, upTo: 8)
            h.clock.suspend(for: 3600)
            awake += offline(h, upTo: 0.5)
            #expect(h.machine.failure == nil, "a resume is retried, not failed")
        }
        awake += offline(h, upTo: 120)
        #expect(h.machine.failure != nil)
        #expect(awake > 28 && awake < 37, "failed \(awake) s of awake time into the outage")
    }

    /// With no network: every request fails at once, until the load fails or `seconds` pass.
    /// Returns the time that passed.
    private func offline(_ h: Harness, upTo seconds: TimeInterval) -> TimeInterval {
        var elapsed = 0.0
        var sent = h.requests.count
        while elapsed < seconds, h.machine.failure == nil {
            if h.requests.count > sent {
                sent = h.requests.count
                h.end(error: -1009)
                continue
            }
            h.clock.advance(by: 0.05)
            elapsed += 0.05
        }
        return elapsed
    }
}
