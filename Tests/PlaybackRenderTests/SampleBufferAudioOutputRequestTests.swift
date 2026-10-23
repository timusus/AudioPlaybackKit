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

    /// Holds each ready-for-more block until the test delivers it, as often as the test likes.
    private final class CuedRenderer: AVSampleBufferAudioRenderer, @unchecked Sendable {
        private let lock = NSLock()
        private var blocks: [(queue: DispatchQueue, block: @Sendable () -> Void)] = []

        var requests: Int { lock.withLock { blocks.count } }

        override func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping @Sendable () -> Void) {
            lock.withLock { blocks.append((queue, block)) }
        }

        /// Runs request `index`'s block on its queue and returns once it has.
        func deliver(_ index: Int) {
            let request = lock.withLock { blocks[index] }
            request.queue.sync(execute: request.block)
        }
    }

    private func makeOutput(_ renderer: AVSampleBufferAudioRenderer? = nil) -> (SampleBufferAudioOutput, Ready) {
        let output = renderer.map { renderer in SampleBufferAudioOutput(newRenderer: { renderer }) } ?? SampleBufferAudioOutput()
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
        let renderer = CuedRenderer()
        let (output, ready) = makeOutput(renderer)

        output.requestMediaDataWhenReady()
        output.requestMediaDataWhenReady()
        XCTAssertEqual(renderer.requests, 1)
        // Apple does not promise that stopping inside the block cancels a delivery already queued.
        renderer.deliver(0)
        renderer.deliver(0)

        XCTAssertEqual(ready.count, 1)
        XCTAssertFalse(output.isRequestingMediaData)
    }

    func testALateRepeatOfAFiredRequestDoesNotAnswerTheNextOne() {
        let renderer = CuedRenderer()
        let (output, ready) = makeOutput(renderer)
        output.requestMediaDataWhenReady()
        renderer.deliver(0)

        output.requestMediaDataWhenReady()
        renderer.deliver(0)
        XCTAssertEqual(ready.count, 1)
        XCTAssertTrue(output.isRequestingMediaData)

        renderer.deliver(1)
        XCTAssertEqual(ready.count, 2)
        XCTAssertFalse(output.isRequestingMediaData)
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
