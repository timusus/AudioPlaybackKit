import Foundation
import Testing
@testable import PlaybackStreaming

/// **A read-ahead in seconds resolves to the byte cap with the probed stream's bitrate (ADR-0013)**,
/// on a 1 MB resource; the byte fallback is 100 kB until the duration is known.
struct GrowingFileDownloadReadAheadSecondsTests {

    private func started(_ setting: GrowingFileReadAhead) -> Harness {
        let h = Harness(readAheadSetting: setting)
        h.pathCost(isExpensive: true)
        h.read()
        h.clock.advance(by: 0.5)
        h.respond(206, range: "bytes 0-999999/1000000", etag: "\"v1\"")
        return h
    }

    @Test("before the probe the byte fallback applies")
    func fallbackBeforeTheProbe() {
        let h = started(GrowingFileReadAhead(seconds: 10, fallbackBytes: 100_000))
        #expect(h.machine.readAhead == 100_000)
        h.body(99_000)
        #expect(h.machine.current?.paused == false)
        h.body(1_000)
        #expect(h.machine.current?.paused == true)
    }

    @Test("a low-bitrate stream (1 MB over 400 s = 20 kbit/s): 10 s is 25 000 bytes, and the cap follows")
    func lowBitrate() {
        let h = started(GrowingFileReadAhead(seconds: 10, fallbackBytes: 100_000))
        h.machine.streamProbed(duration: 400)
        #expect(h.machine.readAhead == 25_000)
        h.body(24_000)
        #expect(h.machine.current?.paused == false)
        h.body(1_000)
        #expect(h.machine.current?.paused == true)
    }

    @Test("a lossless-like stream (1 MB over 5 s = 1.6 Mbit/s): 1 s is 200 000 bytes")
    func losslessLike() {
        let h = started(GrowingFileReadAhead(seconds: 1, fallbackBytes: 100_000))
        h.machine.streamProbed(duration: 5)
        #expect(h.machine.readAhead == 200_000)
        h.body(199_000)
        #expect(h.machine.current?.paused == false)
        h.body(1_000)
        #expect(h.machine.current?.paused == true)
    }

    @Test("a byte read-ahead ignores the duration; an unknown length or zero duration keeps the fallback")
    func unchangedCases() {
        let bytes = started(GrowingFileReadAhead(bytes: 100_000))
        bytes.machine.streamProbed(duration: 400)
        #expect(bytes.machine.readAhead == 100_000)

        let zero = started(GrowingFileReadAhead(seconds: 10, fallbackBytes: 100_000))
        zero.machine.streamProbed(duration: 0)
        #expect(zero.machine.readAhead == 100_000)

        let unknown = Harness(readAheadSetting: GrowingFileReadAhead(seconds: 10, fallbackBytes: 100_000))
        unknown.machine.streamProbed(duration: 400)
        #expect(unknown.machine.readAhead == 100_000, "no length yet")
    }

    @Test("a duration reported before the length is known applies once the first response brings it")
    func durationBeforeTheLength() {
        let h = Harness(readAheadSetting: GrowingFileReadAhead(seconds: 10, fallbackBytes: 100_000))
        h.machine.streamProbed(duration: 400)
        h.pathCost(isExpensive: true)
        h.read()
        h.clock.advance(by: 0.5)
        #expect(h.machine.readAhead == 100_000)
        h.respond(206, range: "bytes 0-999999/1000000", etag: "\"v1\"")
        #expect(h.machine.readAhead == 25_000)
    }

    @Test("a tiny duration is an implausible bitrate: the limit is clamped, not a trap")
    func tinyDurationClamps() {
        let h = started(GrowingFileReadAhead(seconds: 60, fallbackBytes: 100_000))
        h.machine.streamProbed(duration: 1e-9)
        #expect(h.machine.readAhead == GrowingFileReadAhead.ceiling)
        #expect(GrowingFileReadAhead(seconds: 1e9, fallbackBytes: 1).limit(bitsPerSecond: 1e300) == GrowingFileReadAhead.ceiling)
    }

    @Test("a cap that shrinks mid-download pauses at the next chunk; one that grows resumes on the next read")
    func capChangesMidDownload() {
        let h = started(GrowingFileReadAhead(seconds: 10, fallbackBytes: 100_000))
        h.body(60_000)
        #expect(h.machine.current?.paused == false)
        h.machine.streamProbed(duration: 400)
        #expect(h.machine.current?.paused == false, "nothing happens until a chunk arrives")
        h.body(1_000)
        #expect(h.machine.current?.paused == true)

        h.machine.streamProbed(duration: 5)
        #expect(h.machine.readAhead == 2_000_000)
        h.read(1_000)
        #expect(h.machine.current?.paused == false)
        #expect(h.requests.count == 2)
    }
}
