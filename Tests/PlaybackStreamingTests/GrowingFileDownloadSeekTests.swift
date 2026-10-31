import Foundation
import PlaybackDecode
import Testing
@testable import PlaybackStreaming

/// Which seeks the source refuses up front, as media3 gives a stream it cannot seek
/// `SeekMap.Unseekable` instead of failing the read later.
extension GrowingFileDownloadTests {

    @Test("a body of no length answered 200 refuses a seek past its frontier; within it, a seek moves")
    func aRangeIgnoringTranscodeRefusesASeekAhead() throws {
        let h = Harness()
        _ = h.read()
        #expect(h.respond(200))
        h.body(1000)
        #expect(throws: StreamByteReaderError.unseekable) { try h.machine.seek(to: 1001) }
        try h.machine.seek(to: 1000)
        try h.machine.seek(to: 10)
    }

    @Test("a body of no length answered 206 still takes a seek past its frontier")
    func aRangeHonouringBodyOfNoLengthSeeksAhead() throws {
        let h = Harness()
        _ = h.read()
        #expect(h.respond(206, range: "bytes 0-999/*"))
        h.body(1000)
        try h.machine.seek(to: 50_000)
    }

    @Test("before any answer a seek past the frontier is taken")
    func aSeekBeforeTheResponseIsTaken() throws {
        let h = Harness()
        _ = h.read()
        try h.machine.seek(to: 50_000)
    }
}
