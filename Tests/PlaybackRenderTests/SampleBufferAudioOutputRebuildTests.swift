import AVFoundation
@testable @_spi(Testing) import PlaybackRender
import XCTest

/// `rebuild()` without playing: a fresh renderer with the old settings, and no event from the one
/// it replaced. A real reset is checked on device (Developer > Reset Media Services).
final class SampleBufferAudioOutputRebuildTests: XCTestCase {
    func testARebuildReplacesTheRendererAndKeepsItsSettings() throws {
        let output = SampleBufferAudioOutput()
        output.setVolume(0.25)
        let old = output.renderer

        try output.rebuild()

        XCTAssertFalse(output.renderer === old)
        XCTAssertEqual(output.renderer.volume, 0.25)
    }

    func testEventsFromAReplacedRendererAreDropped() throws {
        let output = SampleBufferAudioOutput()
        let events = EventBox()
        output.setEventHandler { events.append($0) }
        let old = output.renderer

        try output.rebuild()
        postAutoFlush(from: old, at: 1)
        postAutoFlush(from: output.renderer, at: 2)

        XCTAssertEqual(events.all, [.autoFlushed(at: 2)])
    }

    /// A new output configuration (e.g. spatial audio) applies only to audio enqueued after it, so
    /// the output asks for a re-feed from what is heard now; the renderer is kept.
    func testAnOutputConfigurationChangeAsksForARefeedFromNow() {
        let output = SampleBufferAudioOutput()
        let events = EventBox()
        output.setEventHandler { events.append($0) }
        let renderer = output.renderer

        NotificationCenter.default.post(name: .AVSampleBufferAudioRendererOutputConfigurationDidChange, object: renderer)

        XCTAssertEqual(events.all, [.autoFlushed(at: 0)])
        XCTAssertTrue(output.renderer === renderer)
    }

    private func postAutoFlush(from renderer: AVSampleBufferAudioRenderer, at seconds: Double) {
        NotificationCenter.default.post(
            name: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: renderer,
            userInfo: [AVSampleBufferAudioRendererFlushTimeKey: NSValue(time: CMTime(seconds: seconds, preferredTimescale: 1000))]
        )
    }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AudioOutputEvent] = []

    var all: [AudioOutputEvent] { lock.withLock { events } }

    func append(_ event: AudioOutputEvent) {
        lock.withLock { events.append(event) }
    }
}

/// The latency is cached: position reads must never reach the session (a blocking IPC on iOS).
final class SampleBufferAudioOutputLatencyTests: XCTestCase {
    private final class Source: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0.0, _reads = 0
        var value: Double { get { lock.withLock { _value } } set { lock.withLock { _value = newValue } } }
        var reads: Int { lock.withLock { _reads } }
        func read() -> Double { lock.withLock { _reads += 1; return _value } }
    }

    func testPositionReadsUseTheCacheAndARefreshFollowsTheRoute() {
        let source = Source()
        source.value = 0.01
        let output = SampleBufferAudioOutput(latencySource: { source.read() })
        output.latencyQueue.sync {}
        XCTAssertEqual(output.outputLatency, 0.01)
        let reads = source.reads

        for _ in 0..<100 { XCTAssertEqual(output.outputLatency, 0.01) }
        XCTAssertEqual(source.reads, reads, "a read must not consult the source")

        source.value = 0.25
        XCTAssertEqual(output.outputLatency, 0.01, "the cache holds until a refresh")
        output.refreshOutputLatency()
        output.latencyQueue.sync {}
        XCTAssertEqual(output.outputLatency, 0.25)
    }
}
