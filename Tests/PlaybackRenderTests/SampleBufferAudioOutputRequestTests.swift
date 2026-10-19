import AVFoundation
@testable @_spi(Testing) import PlaybackRender
import XCTest

/// The ready-for-more request on the real renderer, which is ready while empty, so each arm fires once.
final class SampleBufferAudioOutputRequestTests: XCTestCase {
    private final class Ready: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        private let semaphore = DispatchSemaphore(value: 0)

        var count: Int { lock.withLock { _count } }

        func handle(_ event: AudioOutputEvent) {
            guard case .readyForMoreMediaData = event else { return }
            lock.withLock { _count += 1 }
            semaphore.signal()
        }

        func wait() -> Bool { semaphore.wait(timeout: .now() + 5) == .success }
    }

    private func makeOutput() -> (SampleBufferAudioOutput, Ready) {
        let output = SampleBufferAudioOutput()
        let ready = Ready()
        output.setEventHandler { ready.handle($0) }
        return (output, ready)
    }

    func testARequestFiresOnceAndThenCanBeArmedAgain() {
        let (output, ready) = makeOutput()

        output.requestMediaDataWhenReady()
        XCTAssertTrue(ready.wait())
        XCTAssertEqual(ready.count, 1)
        XCTAssertFalse(output.isRequestingMediaData)

        output.requestMediaDataWhenReady()
        XCTAssertTrue(ready.wait())
        XCTAssertEqual(ready.count, 2)
    }

    func testArmingTwiceBeforeItFiresSendsOneEvent() {
        let (output, ready) = makeOutput()

        output.requestMediaDataWhenReady()
        output.requestMediaDataWhenReady()
        XCTAssertTrue(ready.wait())
        Thread.sleep(forTimeInterval: 0.2)

        XCTAssertEqual(ready.count, 1)
    }

    func testARequestStillWorksAfterAFlush() {
        let (output, ready) = makeOutput()
        output.requestMediaDataWhenReady()
        XCTAssertTrue(ready.wait())

        output.flush()
        output.requestMediaDataWhenReady()

        XCTAssertTrue(ready.wait())
        XCTAssertEqual(ready.count, 2)
    }

    func testARebuildDropsTheOldRequestAndTheNewRendererArmsOwn() throws {
        let (output, ready) = makeOutput()
        output.requestMediaDataWhenReady()
        try output.rebuild()
        XCTAssertFalse(output.isRequestingMediaData)
        // The old callback may have fired before the rebuild; nothing from it can follow.
        let before = ready.count

        output.requestMediaDataWhenReady()
        let deadline = Date().addingTimeInterval(5)
        while ready.count == before, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        Thread.sleep(forTimeInterval: 0.2)

        XCTAssertEqual(ready.count, before + 1, "only the new renderer's request reaches the handler")
        XCTAssertFalse(output.isRequestingMediaData)
    }
}
