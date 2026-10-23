import PlaybackRender
import PlaybackRenderTestSupport
import XCTest

/// What an app's own test target can do: only public imports, no `@testable`, no SPI.
final class ExternalConsumerTests: XCTestCase {
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [TransportEvent<String>] = []

        var all: [TransportEvent<String>] { lock.withLock { _all } }
        func append(_ event: TransportEvent<String>) { lock.withLock { _all.append(event) } }
    }

    func testAppCanDriveATransportOnTheFakeOutputAndObservePositions() {
        let output = FakeAudioOutput()
        let timer = ManualPumpTimer()
        let executor = ManualExecutor()
        let events = Events()
        let transport = Transport<String>(output: output, timer: timer, executor: executor) { events.append($0) }
        let format = PCMFormat(sampleRate: 8, channelCount: 1)

        transport.setCurrent(item: "a", source: FakeItemSource(format: format, frames: 24, chunkFrames: 2))
        transport.play()
        for _ in 0..<4 {
            timer.sync()
            executor.runUntilIdle()
            timer.fire()
            output.advance(by: 0.25)
        }
        timer.fire()

        XCTAssertEqual(transport.position?.item, "a")
        XCTAssertEqual(transport.position?.seconds, 1)
        XCTAssert(events.all.contains { if case .landed("a", 0) = $0 { true } else { false } })
    }

    func testAppCanObserveTimeWithATokenItKeeps() {
        let output = FakeAudioOutput()
        let timer = ManualPumpTimer()
        let executor = ManualExecutor()
        let transport = Transport<String>(output: output, timer: timer, executor: executor) { _ in }
        let fired = NSLock()
        nonisolated(unsafe) var times: [TimeInterval] = []
        transport.setCurrent(item: "a", source: FakeItemSource(format: PCMFormat(sampleRate: 8, channelCount: 1),
                                                               frames: 24, chunkFrames: 2))
        transport.play()
        let token = transport.addBoundaryObserver(times: [0.5]) { _, time in fired.withLock { times.append(time) } }
        timer.advance(by: 1, clock: output.advance(by:), settle: executor.runUntilIdle)

        XCTAssertEqual(fired.withLock { times }, [0.5])
        token.cancel()
    }
}
