import PlaybackDecode
import PlaybackStreaming
import PlaybackStreamingTestSupport
import XCTest

final class StreamAURLRecipe: XCTestCase {
    // The server closes every connection mid-body, as a flaky link does. The byte source resumes
    // with a `Range` request from where the bytes stopped; the decoder never notices.
    func testStreamAURLAndResumeAfterADroppedConnection() throws {
        let server = try LoopbackMediaServer(body: Tone.wav(seconds: 20), mimeType: "audio/wav")
        defer { server.stop() }
        server.closesAfterBodyBytes = 100_000

        let source = GrowingFileByteSource(
            url: server.url,
            authHeaders: [:], // already resolved; add "Authorization" here for a private feed
            store: .temporary() // an app uses `.shared`, or a store of its own
        )
        // The source and its partial file live until cancelled.
        defer { source.cancel() }

        let decoder = FFmpegStreamDecoder(reader: source)
        // Lets FFmpeg's MP3 footer probe read end-of-file instead of cancelling the head download.
        source.isProbing = true
        let format = try decoder.open()
        source.isProbing = false

        var frames = 0
        while let chunk = decoder.nextChunk() {
            frames += chunk.count / format.channelCount
        }

        XCTAssertEqual(decoder.endReason, .eof)
        XCTAssertEqual(frames, 20 * 8000)
        XCTAssertGreaterThan(server.requestedRanges.count, 1, "the drop was not resumed with a new request")
        XCTAssertGreaterThan(server.requestedRanges.last ?? 0, 0, "the resume asked from the start again")
    }
}
