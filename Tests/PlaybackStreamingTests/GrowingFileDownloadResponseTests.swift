import Foundation
import PlaybackDecode
import Testing

@testable import PlaybackStreaming

/// Reading a response's headers, per RFC 9110's Content-Range forms.
extension GrowingFileDownloadTests {

    @Test("a Content-Range gives its start and total, a nil total for *, and nothing when malformed")
    func contentRangeParses() {
        #expect(GrowingFileDownload.contentRange("bytes 100-199/1000")! == (100, 1000))
        #expect(GrowingFileDownload.contentRange("bytes 0-99/*")! == (0, nil))
        #expect(GrowingFileDownload.contentRange("bytes */1000") == nil)
        #expect(GrowingFileDownload.contentRange("items 0-99/1000") == nil)
        #expect(GrowingFileDownload.contentRange("bytes x-99/1000") == nil)
        #expect(GrowingFileDownload.contentRange(nil) == nil)
    }

    @Test("a 416 for */base or a 206 clamped to end at base says the resource ends at base; nothing else does")
    func totalEndingAtReadsOnlyAnEndAtTheBase() {
        #expect(GrowingFileDownload.totalEndingAt(1000, status: 416, contentRange: "bytes */1000") == 1000)
        #expect(GrowingFileDownload.totalEndingAt(1000, status: 416, contentRange: "bytes */2000") == nil)
        #expect(GrowingFileDownload.totalEndingAt(1000, status: 206, contentRange: "bytes 900-999/1000") == 1000)
        #expect(GrowingFileDownload.totalEndingAt(1000, status: 206, contentRange: "bytes 1000-1099/2000") == nil)
        #expect(GrowingFileDownload.totalEndingAt(1000, status: 206, contentRange: "bytes 900-999/*") == nil)
        #expect(GrowingFileDownload.totalEndingAt(1000, status: 200, contentRange: "bytes */1000") == nil)
        #expect(GrowingFileDownload.totalEndingAt(1000, status: 416, contentRange: nil) == nil)
    }

    @Test("a page type is never media, an audio or video type always is, and an unnamed type waits for the sniff")
    func isMediaByType() {
        #expect(GrowingFileDownload.isMedia(mimeType: "text/html") == false)
        #expect(GrowingFileDownload.isMedia(mimeType: "Application/XHTML+XML") == false)
        #expect(GrowingFileDownload.isMedia(mimeType: "audio/mpeg") == true)
        #expect(GrowingFileDownload.isMedia(mimeType: "video/mp4") == true)
        #expect(GrowingFileDownload.isMedia(mimeType: "application/ogg") == true)
        #expect(GrowingFileDownload.isMedia(mimeType: "application/octet-stream") == nil)
        #expect(GrowingFileDownload.isMedia(mimeType: nil) == nil)
        #expect(GrowingFileDownload.isMedia(mimeType: "application/octet-stream", head: Array("ID3".utf8)) == false)
    }

    /// media3's DefaultHttpDataSource takes any 2xx; one other than 206 is the whole body, like a 200.
    @Test("a 203 is a whole body like a 200, and to a ranged request it means the range is ignored")
    func anyOther2xxIsAWholeBody() throws {
        let h = Harness()
        h.read()
        #expect(h.respond(203, length: 10000))
        #expect(h.events == [.transaction(base: 0, generation: 1, seekGeneration: nil, httpStatus: 203)])
        h.body(10000)
        h.end()
        #expect(h.machine.totalLength == 10000)
        #expect(h.read(100) == .serve(fileOffset: 0, count: 100, landed: nil))

        let ranged = Harness()
        try ranged.machine.seek(to: 5000)
        #expect(ranged.read() == .park)
        #expect(ranged.requests == [ranged.request(1, from: 5000)])
        #expect(ranged.respond(203, length: 10000))
        #expect(ranged.machine.rangeIgnored)
        #expect(ranged.machine.current?.bodyAt == 0)

        // A resume from byte 0 answered 203 with the whole length is the range asked for.
        let resumed = Harness()
        resumed.startWithDrop()
        resumed.clock.advance(by: 0.1)
        #expect(resumed.requests.last == resumed.request(2, from: 0))
        #expect(resumed.respond(203, length: 100000))
        #expect(resumed.opens == 1, "no restart")
    }

    /// media3's `HttpUtil.getContentLength` (used by DefaultHttpDataSource) warns on a `Content-Length`
    /// that disagrees with the `Content-Range` span and takes the larger. This engine deviates on
    /// the total: the range's own total is the resource's length and the body's header is only
    /// what is left to send, so neither a short nor a long header changes it or fails the read.
    @Test("a Content-Length that disagrees with the Content-Range leaves the range's total and the read intact")
    func aContentLengthDisagreeingWithTheContentRangeKeepsTheRangesTotal() {
        for lie: Int64 in [400, 5000] {
            let h = Harness()
            h.read()
            #expect(h.respond(206, range: "bytes 0-999/1000", length: lie), "length \(lie)")
            #expect(h.machine.totalLength == 1000, "length \(lie)")
            h.body(1000)
            h.end()
            #expect(h.machine.totalLength == 1000, "length \(lie)")
            #expect(h.read(100) == .serve(fileOffset: 0, count: 100, landed: nil), "length \(lie)")
        }
    }

    @Test("a 204 with no body and no type is no media: the read fails")
    func aNoContentResponseFailsTheRead() {
        let h = Harness()
        h.read()
        #expect(h.respond(204, length: 0, mimeType: "application/octet-stream"))
        h.end()
        #expect(h.read() == .fail(.failed(StreamFailure(.unsupported, detail: "not audio: body of 0 bytes"))))
    }
}
