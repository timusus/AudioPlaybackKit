import XCTest
import PlaybackStreamingTestSupport
@testable import PlaybackStreaming

extension GrowingFileByteSourceTests {
    /// The counted download is the hop after a tracking redirect, on another origin: the app's
    /// User-Agent rides it and every restart, while the auth header stays on the original origin.
    func testTheUserAgentSurvivesACrossOriginRedirectAndARestartWhileAuthDoesNot() throws {
        let body = makeBody(64 * 1024)
        let agent = "ShuttlePodcasts/1.2 (iOS; +https://shuttlepodcasts.app)"
        let server = try startServer(body: body)
        server.redirectsToAlternateHost = true
        let source = makeSource(
            server.redirectingURL(hops: 1), authHeaders: ["Authorization": "Basic c2VjcmV0"], userAgent: agent
        )
        XCTAssertEqual(try read(source, 100), body.prefix(100))

        let first = try XCTUnwrap(server.requestHeads.first { $0.lowercased().contains("host: 127.0.0.1") }).lowercased()
        let landed = try XCTUnwrap(server.requestHeads.first { $0.lowercased().contains("host: localhost") }).lowercased()
        XCTAssertTrue(first.contains("user-agent: \(agent.lowercased())"), first)
        XCTAssertTrue(landed.contains("user-agent: \(agent.lowercased())"), landed)
        XCTAssertFalse(landed.contains("authorization:"), landed)

        // A restart goes straight to the redirected end.
        try source.seek(to: 40_000)
        XCTAssertEqual(try read(source, 100), body.subdata(in: 40_000..<40_100))
        let restart = try XCTUnwrap(server.requestHeads.last).lowercased()
        XCTAssertTrue(restart.contains("host: localhost"), restart)
        XCTAssertTrue(restart.contains("user-agent: \(agent.lowercased())"), restart)
        XCTAssertFalse(restart.contains("authorization:"), restart)
    }
}
