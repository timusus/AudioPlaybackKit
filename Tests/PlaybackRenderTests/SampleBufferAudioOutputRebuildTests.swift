import AVFoundation
@testable import PlaybackRender
import XCTest

/// The adapter's `rebuild()` without playing: a fresh renderer with the settings it had, and no
/// event from the renderer it replaced. The failure itself is checked on device (Settings >
/// Developer > Reset Media Services).
final class SampleBufferAudioOutputRebuildTests: XCTestCase {
    func testARebuildReplacesTheRendererAndKeepsItsSettings() throws {
        let output = SampleBufferAudioOutput()
        output.setVolume(0.25)
        let old = output.renderer

        try output.rebuild()

        XCTAssertFalse(output.renderer === old)
        XCTAssertEqual(output.renderer.volume, 0.25)
        XCTAssertEqual(output.renderer.audioTimePitchAlgorithm, .timeDomain)
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
