import Foundation
import PlaybackDecode
import Testing

@testable import PlaybackStreaming

/// **The ends of a download's life, driven event by event with no server**: a partial that cannot
/// be made, a cancel, a path that starts to cost mid-body, and the `download` event.
struct GrowingFileDownloadLifecycleTests {

    @Test("a partial that cannot be made fails the read that asked for it, and no request goes out")
    func anUnopenableFileFailsTheRead() {
        let h = Harness()
        let first = h.machine.read(maxLength: 1000, now: h.now)
        #expect(first.effects == [.openFile])
        #expect(first.action == .again)

        h.run(h.machine.opened(fileReady: false, now: h.now))
        #expect(h.requests.isEmpty)
        let second = h.machine.read(maxLength: 1000, now: h.now)
        #expect(second.action == .fail(.transport("cannot open a partial")))
        #expect(h.machine.current == nil)
    }

    @Test("a seek after cancel throws cancelled, mid-body and again on a repeat cancel")
    func aSeekAfterCancelThrows() throws {
        let h = Harness()
        h.read()
        h.respond(206, range: "bytes 0-9999/10000")
        h.body(1000)
        try h.machine.seek(to: 500)

        h.run(h.machine.cancel())
        #expect(throws: StreamByteReaderError.cancelled) { try h.machine.seek(to: 600) }
        #expect(h.machine.cancel().isEmpty)
        #expect(throws: StreamByteReaderError.cancelled) { try h.machine.seek(to: 0) }
        #expect(h.machine.offset == 500, "the refused seek moved nothing")
        #expect(h.read() == .fail(.cancelled))
    }

    @Test("a path that starts to cost mid-body pauses the request at the next chunk, not at once")
    func aCostlyPathPausesAtTheNextChunk() {
        let h = Harness(readAhead: 100_000)
        h.pathCost(isExpensive: false)
        h.read()
        h.respond(206, range: "bytes 0-999999/1000000", etag: "\"v1\"")
        h.body(150_000)
        #expect(h.machine.current?.paused == false, "a cheap path downloads whole, past the read-ahead")

        h.pathCost(isExpensive: true)
        #expect(h.machine.current?.paused == false, "the switch alone cancels nothing")
        #expect(!h.log.contains(.cancelTask))

        h.body(1_000)
        #expect(h.machine.current?.paused == true)
        #expect(h.log.last(where: { $0 != .wake }) == .cancelTask)
        #expect(h.machine.retry.attempts == 0, "a pause is no failure")
    }

    @Test("a download event follows the first chunk, then at most one a second, and one at completion")
    func downloadEventsAreRateLimitedAndEndComplete() {
        let h = Harness()
        let downloads = { h.events.compactMap { event -> (Int64, Bool)? in
            if case let .download(frontier, _, complete) = event { (frontier, complete) } else { nil }
        } }
        h.read()
        h.respond(206, range: "bytes 0-9999/10000")
        #expect(downloads().isEmpty, "the response alone is no movement")

        h.body(1000)
        #expect(downloads().map(\.0) == [1000])
        h.clock.advance(by: 0.5)
        h.body(1000)
        #expect(downloads().count == 1, "inside the second")
        h.clock.advance(by: 0.5)
        h.body(1000)
        #expect(downloads().map(\.0) == [1000, 3000])
        #expect(downloads().map(\.1) == [false, false])

        h.body(7000)
        h.end()
        #expect(downloads().last?.0 == 10_000)
        #expect(downloads().last?.1 == true)
    }
}
