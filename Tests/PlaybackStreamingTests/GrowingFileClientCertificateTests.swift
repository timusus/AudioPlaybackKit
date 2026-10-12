import XCTest
@testable import PlaybackStreaming

/// The loopback server speaks no TLS, so a client-certificate challenge is driven at the delegate.
final class GrowingFileClientCertificateTests: XCTestCase {

    private final class NoSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    private let sender = NoSender()
    private let origin = URL(string: "https://media.example:8443/a.mp3")!
    private var directory: URL!
    private var source: GrowingFileByteSource?

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("client-cert-\(UUID().uuidString)")
    }

    override func tearDown() {
        source?.cancel()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeSource(
        clientCredential: (@Sendable (URLProtectionSpace) -> URLCredential?)?
    ) -> GrowingFileByteSource {
        let made = GrowingFileByteSource(
            url: origin, authHeaders: [:], clientCredential: clientCredential,
            store: GrowingFileStore(directory: directory), clock: ManualGrowingFileClock(), pathMonitor: GrowingFilePathMonitor()
        )
        source = made
        return made
    }

    private func answer(
        _ source: GrowingFileByteSource, host: String = "media.example", method: String = NSURLAuthenticationMethodClientCertificate
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = URLProtectionSpace(host: host, port: 8443, protocol: "https", realm: nil, authenticationMethod: method)
        let challenge = URLAuthenticationChallenge(
            protectionSpace: space, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil, sender: sender
        )
        var result: (URLSession.AuthChallengeDisposition, URLCredential?)?
        source.urlSession(URLSession.shared, task: URLSession.shared.dataTask(with: origin), didReceive: challenge) {
            result = ($0, $1)
        }
        return result!
    }

    func testTheProvidersCredentialAnswersTheOriginsClientCertificateChallenge() {
        let credential = URLCredential(user: "identity", password: "stand-in", persistence: .forSession)
        let source = makeSource { space in space.host == "media.example" ? credential : nil }
        let (disposition, used) = answer(source)
        XCTAssertEqual(disposition, .useCredential)
        XCTAssertTrue(used === credential)
    }

    func testNoProviderLeavesTheSystemsHandling() {
        let (disposition, used) = answer(makeSource(clientCredential: nil))
        XCTAssertEqual(disposition, .performDefaultHandling)
        XCTAssertNil(used)
    }

    func testAProviderReturningNilLeavesTheSystemsHandling() {
        let (disposition, used) = answer(makeSource { _ in nil })
        XCTAssertEqual(disposition, .performDefaultHandling)
        XCTAssertNil(used)
    }

    func testTheIdentityIsNotOfferedToAnotherOrigin() {
        let credential = URLCredential(user: "identity", password: "stand-in", persistence: .forSession)
        let (disposition, used) = answer(makeSource { _ in credential }, host: "cdn.example")
        XCTAssertEqual(disposition, .performDefaultHandling)
        XCTAssertNil(used)
    }

    func testOtherAuthenticationMethodsDoNotReachTheProvider() {
        let credential = URLCredential(user: "identity", password: "stand-in", persistence: .forSession)
        let (disposition, used) = answer(makeSource { _ in credential }, method: NSURLAuthenticationMethodHTTPBasic)
        XCTAssertEqual(disposition, .performDefaultHandling)
        XCTAssertNil(used)
    }
}
