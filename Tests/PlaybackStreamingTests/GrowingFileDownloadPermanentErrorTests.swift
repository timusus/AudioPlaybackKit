import Foundation
import PlaybackDecode
import Testing
@testable import PlaybackStreaming

/// **URL errors no retry fixes fail the read at once** (#164), with the one request sent.
struct GrowingFileDownloadPermanentErrorTests {

    @Test("a certificate, TLS, ATS or bad-URL error fails the read without a retry", arguments: [-1201, -1202, -1206, -1022, -1000, -1002])
    func permanentCodesFailAtOnce(code: Int) {
        let h = Harness()
        #expect(h.read() == .park)
        h.end(error: code)
        let failure = StreamFailure(.network, detail: "error=\(code)", urlError: URLError(URLError.Code(rawValue: code)))
        #expect(h.read() == .fail(.failed(failure)))
        #expect(h.requests.count == 1)
        #expect(h.machine.retry.failuresInRow == 0)
    }

    @Test("a transient code is retried, and so is a permanent code from another domain")
    func otherErrorsAreRetried() {
        let h = Harness()
        h.read()
        h.end(error: -1005)
        h.clock.advance(by: 1)
        #expect(h.requests.count == 2)
        h.end(error: -1202, domain: "NSPOSIXErrorDomain")
        h.clock.advance(by: 1)
        #expect(h.requests.count == 3)
        h.end(error: -1200)
        h.clock.advance(by: 1)
        #expect(h.requests.count == 4)
    }
}
