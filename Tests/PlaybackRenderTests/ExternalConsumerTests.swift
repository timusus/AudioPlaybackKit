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

        let frames = events.all.compactMap { event -> Int64? in
            guard case let .position(item, frame, sampleRate, _) = event, item == "a", sampleRate == 8 else { return nil }
            return frame
        }
        XCTAssertEqual(frames.last, 8)
    }
}
