#if os(macOS)
import CoreAudio
import PlaybackRender
import XCTest

/// The real renderer through `Transport`'s public API only (no `@testable`), on the Mac's default
/// output: a 1 s tone plays, seeks and speeds up in wall time.
final class SampleBufferAudioOutputIntegrationTests: XCTestCase {
    /// How late `.ended` may arrive past the audio's end on an idle Mac: the clock starts ~0.1 s after
    /// `.playing`, macOS coalesces the 0.1 s pump to 0.2 s, and the synchronizer's rate change at the
    /// end blocks up to ~0.2 s (MacBook Pro, built-in speakers). A loaded machine delays it by seconds
    /// while the position rate stays exact, so the bound is checked only with `RENDER_EVENT_BOUNDS=1`.
    private static let eventLatency: TimeInterval? =
        RenderEventBounds.enabled ? 0.75 : nil
    private let recorder = TimedRecorder()
    private var transport: Transport<String>!
    private var sampling: TimeObserverToken?

    override func setUpWithError() throws {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        try XCTSkipUnless(status == noErr && device != kAudioObjectUnknown, "no audio output device")
        let transport = Transport<String> { [recorder] in recorder.append($0) }
        // Sampled as a UI would read it; weak, as the transport holds its observers.
        sampling = transport.addPeriodicObserver(interval: 0.05) { [recorder, weak transport] in
            recorder.sample(transport?.position)
        }
        self.transport = transport
    }

    override func tearDown() {
        sampling = nil
        transport = nil
    }

    /// Waits for `expectations`, then reads the position once more: the read at `.ended` is the end.
    private func waitAndRead(for expectations: [XCTestExpectation], enforceOrder: Bool = false) {
        wait(for: expectations, timeout: 5, enforceOrder: enforceOrder)
        recorder.sample(transport.position)
    }

    func testAToneReportsPlayingThenAdvancingPositionsThenEndedInRealTime() {
        let playing = recorder.expect { $0.status == .playing }
        let ended = recorder.expect { $0.status == .ended }
        let playAt = recorder.now
        transport.setCurrent(item: "tone", source: ToneSource())
        transport.play()
        waitAndRead(for: [playing, ended], enforceOrder: true)

        let timing = recorder.timing(from: .playing, to: .ended)
        print("1x: playing \(recorder.elapsed(to: .playing) - playAt) s after play(), ended \(timing) s later; \(recorder.positionRate(sampleRate: 48000)) media s per wall s")
        // The clock tracks wall time: 1 s of audio is heard in about a second.
        XCTAssertEqual(recorder.positionRate(sampleRate: 48000), 1, accuracy: 0.02)
        XCTAssertGreaterThan(timing, 0.9)
        if let latency = Self.eventLatency { XCTAssertLessThan(timing, 1 + latency) }
        let frames = recorder.positions
        XCTAssertGreaterThan(Set(frames).count, 5)
        XCTAssertEqual(frames, frames.sorted())
        XCTAssertEqual(frames.last, 48000)
    }

    func testASeekMidItemPlaysOnFromThere() {
        let quarter = recorder.expect { ($0.frame ?? 0) >= 12000 }
        transport.setCurrent(item: "tone", source: ToneSource())
        transport.play()
        wait(for: [quarter], timeout: 5)

        let ended = recorder.expect { $0.status == .ended }
        let seekAt = recorder.now
        transport.seek(item: "tone", toSeconds: 0.75)
        waitAndRead(for: [ended])

        // The seek's restart reports `.buffering` before any position of its own.
        let afterSeek = recorder.positions(afterStatus: .buffering, since: seekAt)
        // From the seek's own `.playing`: the flush and refill before it are not audio.
        let timing = recorder.timing(from: .playing, to: .ended)
        print("seek: \(afterSeek.count) positions from \(afterSeek.first ?? -1), ended \(recorder.elapsed(to: .ended) - seekAt) s after the seek, \(timing) s after playing")
        // The last quarter second plays out; the skipped half never does.
        XCTAssertEqual(afterSeek.first, 36000)
        XCTAssertEqual(afterSeek, afterSeek.sorted())
        XCTAssertEqual(afterSeek.last, 48000)
        XCTAssertGreaterThan(timing, 0.2)
        if let latency = Self.eventLatency { XCTAssertLessThan(timing, 0.25 + latency) }
    }

    func testAtRateTwoTheToneEndsInHalfTheTime() {
        let playing = recorder.expect { $0.status == .playing }
        let ended = recorder.expect { $0.status == .ended }
        transport.setRate(2)
        transport.setCurrent(item: "tone", source: ToneSource())
        transport.play()
        waitAndRead(for: [playing, ended], enforceOrder: true)

        let timing = recorder.timing(from: .playing, to: .ended)
        print("2x: ended \(timing) s after playing; \(recorder.positionRate(sampleRate: 48000)) media s per wall s")
        XCTAssertEqual(recorder.positionRate(sampleRate: 48000), 2, accuracy: 0.04)
        XCTAssertGreaterThan(timing, 0.4)
        if let latency = Self.eventLatency { XCTAssertLessThan(timing, 0.5 + latency) }
        XCTAssertEqual(recorder.positions.last, 48000)
    }
}

/// One second of a 440 Hz stereo sine at 48 kHz, in 100 ms chunks; seeks are exact.
private final class ToneSource: ItemSource, @unchecked Sendable {
    private var frame: Int64 = 0
    let frameCount: Int64? = 48000

    func begin(epoch: UInt64) {}
    func open() throws -> PCMFormat { PCMFormat(sampleRate: 48000, channelCount: 2) }

    func seek(toFrame frame: Int64) throws -> Int64 {
        self.frame = min(frame, 48000)
        return self.frame
    }

    func nextChunk() throws -> [Float]? {
        guard frame < 48000 else { return nil }
        let end = min(frame + 4800, 48000)
        defer { frame = end }
        return (frame..<end).flatMap { f -> [Float] in
            let sample = 0.1 * Float(sin(2 * Double.pi * 440 * Double(f) / 48000))
            return [sample, sample]
        }
    }

    func interrupt(through epoch: UInt64) {}
    func release() {}
}

/// Every event and position read with the wall time it arrived, and expectations fulfilled by the
/// first matching one.
private final class TimedRecorder: @unchecked Sendable {
    struct Entry {
        var event: TransportEvent<String>?
        var read: TimeInterval?
        var at: TimeInterval

        var status: TransportStatus? { if case let .status(status) = event { status } else { nil } }
        var frame: Int64? {
            if case let .landed(_, seconds) = event { return Int64((seconds * 48000).rounded()) }
            return read.map { Int64(($0 * 48000).rounded()) }
        }
    }

    private let lock = NSLock()
    private let start = Date()
    private var entries: [Entry] = []
    private var pending: [(match: (Entry) -> Bool, expectation: XCTestExpectation)] = []

    func append(_ event: TransportEvent<String>) {
        record(Entry(event: event, at: Date().timeIntervalSince(start)))
    }

    func sample(_ position: TransportPosition<String>?) {
        guard let position else { return }
        record(Entry(read: position.seconds, at: Date().timeIntervalSince(start)))
    }

    private func record(_ entry: Entry) {
        let met = lock.withLock {
            entries.append(entry)
            let met = pending.filter { $0.match(entry) }.map(\.expectation)
            pending.removeAll { $0.match(entry) }
            return met
        }
        met.forEach { $0.fulfill() }
    }

    func expect(_ match: @escaping (Entry) -> Bool) -> XCTestExpectation {
        let expectation = XCTestExpectation()
        lock.withLock { pending.append((match, expectation)) }
        return expectation
    }

    /// Seconds since the recorder started, on the events' clock.
    var now: TimeInterval { Date().timeIntervalSince(start) }

    var positions: [Int64] { lock.withLock { entries.compactMap(\.frame) } }

    /// Positions after the first `status` event at or after `time`.
    func positions(afterStatus status: TransportStatus, since time: TimeInterval) -> [Int64] {
        lock.withLock {
            guard let index = entries.firstIndex(where: { $0.at >= time && $0.status == status }) else { return [] }
            return entries[(index + 1)...].compactMap(\.frame)
        }
    }

    /// Seconds from the recorder's start to the last event with `status`.
    func elapsed(to status: TransportStatus) -> TimeInterval {
        lock.withLock { entries.last { $0.status == status }?.at ?? .nan }
    }

    /// Media seconds per wall second between the first and last position short of the item's end.
    func positionRate(sampleRate: Double) -> Double {
        lock.withLock {
            let heard = entries.compactMap { entry in entry.frame.map { (frame: $0, at: entry.at) } }
                .filter { $0.frame > 0 && $0.frame < 48000 }
            guard let first = heard.first, let last = heard.last, last.at > first.at else { return .nan }
            return Double(last.frame - first.frame) / sampleRate / (last.at - first.at)
        }
    }

    func timing(from: TransportStatus, to: TransportStatus) -> TimeInterval {
        elapsed(to: to) - elapsed(to: from)
    }
}
#endif
