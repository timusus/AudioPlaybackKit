#if os(macOS)
import AVFoundation
import CoreAudio
@testable import PlaybackRender
import XCTest

/// The real renderer on Apple's two documented auto-flush triggers, a rate change and an output
/// device switch, through `Transport`. Whatever Apple does, the media timeline the core enqueues
/// must stay continuous: a restart resumes at the media frame the flush time maps to.
final class SampleBufferAudioOutputAutoFlushTests: XCTestCase {
    private let log = EventLog()
    private var renderer: SampleBufferAudioOutput!
    private var output: RecordingOutput!
    private var transport: Transport<String>!

    override func setUpWithError() throws {
        try XCTSkipUnless(defaultOutputDevice() != nil, "no audio output device")
        renderer = SampleBufferAudioOutput()
        output = RecordingOutput(renderer)
        transport = Transport<String>(output: output) { [log] in log.append($0) }
    }

    override func tearDown() {
        transport = nil
        output = nil
        renderer = nil
    }

    func testRateChangesMidItemKeepTheMediaTimelineContinuous() {
        let playing = log.expect { $0.status == .playing }
        let ended = log.expect { $0.status == .ended }
        transport.setCurrent(item: "ramp", source: RampSource())
        transport.play()
        wait(for: [playing], timeout: 5)
        // 0.5 s at 1x, 0.75 s at 2x, 0.75 s at 1x, then the last second at 0.5x.
        for (frame, rate) in [(Int64(24000), 2.0), (60000, 1), (96000, 0.5)] {
            wait(for: [log.expect { ($0.frame ?? 0) >= frame }], timeout: 5)
            transport.setRate(rate)
        }
        wait(for: [ended], timeout: 10)

        let wall = log.timing(from: .playing, to: .ended)
        print("rate 1-2-1-0.5: \(output.summary()); playing to ended \(wall) s")
        // About 3.6 s of wall time, so every rate took effect.
        XCTAssertGreaterThan(wall, 3.2)
        XCTAssertLessThan(wall, 5)
        assertContinuous()
    }

    func testSwitchingOutputDeviceMidItemKeepsTheMediaTimelineContinuous() throws {
        let target = try otherOutputDevice()
        let configurationChanges = NotificationCounter(.AVSampleBufferAudioRendererOutputConfigurationDidChange)
        let playing = log.expect { $0.status == .playing }
        let ended = log.expect { $0.status == .ended }
        transport.setCurrent(item: "ramp", source: RampSource())
        transport.play()
        wait(for: [playing, log.expect { ($0.frame ?? 0) >= 24000 }], timeout: 5, enforceOrder: true)
        renderer.audioOutputDeviceUniqueID = target
        wait(for: [ended], timeout: 10)

        let wall = log.timing(from: .playing, to: .ended)
        print("device switch to \(target): \(output.summary()); outputConfigurationDidChange fired \(configurationChanges.count) times; playing to ended \(wall) s")
        XCTAssertEqual(renderer.audioOutputDeviceUniqueID, target)
        XCTAssertGreaterThan(wall, 2.9)
        // The restart is silent about 150 ms, the renderer's own: its first enqueue to the new device
        // blocks about 55 ms and its clock starts about 70 ms after the rate is set.
        XCTAssertLessThan(wall, 3.45)
        // The macOS clock includes the device's latency, so the adapter reports 0 on any device.
        XCTAssertEqual(output.latencies, [0])
        // Up to the written end: past it the feeder holds the clock back at the end by design.
        let writtenEnd = try XCTUnwrap(output.runs.last?.enqueues.last?.endTime)
        let clock = output.clockReadings.filter { $0 <= writtenEnd }
        XCTAssertEqual(clock, clock.sorted(), "the synchronizer clock went backwards")
        assertContinuous()
    }

    /// The item plays to its last frame, every restart after audio was written follows an auto-flush
    /// and resumes at the media frame that was at the flush time, and positions never go back.
    private func assertContinuous(file: StaticString = #filePath, line: UInt = #line) {
        let runs = output.runs
        let positions = log.positions
        for (previous, next) in zip(positions, positions.dropFirst()) where next < previous {
            XCTFail("position \(previous) went back to \(next)", file: file, line: line)
        }
        XCTAssertEqual(positions.last, RampSource.frames, file: file, line: line)

        XCTAssertEqual(runs.last?.enqueues.last?.endFrame, RampSource.frames, file: file, line: line)
        for run in runs {
            for (previous, next) in zip(run.enqueues, run.enqueues.dropFirst()) {
                XCTAssertEqual(next.time, previous.endTime, accuracy: 1 / 48000, "a hole or overlap in output time", file: file, line: line)
                XCTAssertEqual(next.firstFrame, previous.endFrame, "a gap or repeat in media frames", file: file, line: line)
            }
        }
        for (previous, next) in zip(runs, runs.dropFirst()) {
            guard let flushTime = next.autoFlushTime else {
                XCTFail("a restart with no auto-flush before it", file: file, line: line)
                continue
            }
            let heard = previous.mediaFrame(at: flushTime)
            let resumed = next.enqueues[0].firstFrame
            print("auto-flush at \(flushTime): heard frame \(heard), resumed at \(resumed) (\(resumed - heard) frames)")
            XCTAssertEqual(resumed, heard, accuracy: 1, "the re-feed does not resume at the flush time", file: file, line: line)
        }
    }
}

/// Three seconds at 48 kHz stereo in 100 ms chunks. The right channel is the frame index over
/// 2^24, exact in Float32, so any enqueued chunk names the media frame it starts at.
private final class RampSource: ItemSource, @unchecked Sendable {
    static let frames: Int64 = 144_000
    private var frame: Int64 = 0

    func begin(epoch: UInt64) {}
    func open() throws -> PCMFormat { PCMFormat(sampleRate: 48000, channelCount: 2) }

    func seek(toFrame frame: Int64) throws -> Int64 {
        self.frame = min(frame, Self.frames)
        return self.frame
    }

    func nextChunk() throws -> [Float]? {
        guard frame < Self.frames else { return nil }
        let end = min(frame + 4800, Self.frames)
        defer { frame = end }
        return (frame..<end).flatMap { f -> [Float] in
            [0.05 * Float(sin(2 * Double.pi * 440 * Double(f) / 48000)), Float(f) / 16_777_216]
        }
    }

    func interrupt(through epoch: UInt64) {}
}

/// The real output with every call the feeder makes and every auto-flush it reports, in order.
private final class RecordingOutput: AudioOutput, @unchecked Sendable {
    struct Enqueue {
        var time: TimeInterval
        var firstFrame: Int64
        var frameCount: Int64
        var endTime: TimeInterval { time + Double(frameCount) / 48000 }
        var endFrame: Int64 { firstFrame + frameCount }
    }

    /// Enqueues between two flushes, and the earliest auto-flush reported before the flush that
    /// started them: the time the feeder restarts from.
    struct Run {
        var autoFlushTime: TimeInterval?
        var enqueues: [Enqueue] = []

        func mediaFrame(at time: TimeInterval) -> Int64 {
            guard let enqueue = enqueues.last(where: { $0.time <= time }) else { return enqueues[0].firstFrame }
            return min(enqueue.firstFrame + Int64(((time - enqueue.time) * 48000).rounded()), enqueue.endFrame)
        }
    }

    private let base: SampleBufferAudioOutput
    private let lock = NSLock()
    private var allRuns = [Run()]
    private var pendingAutoFlush: TimeInterval?
    private var autoFlushes: [(at: TimeInterval, clock: TimeInterval)] = []
    private var readings: [TimeInterval] = []
    private var latencyReadings: Set<TimeInterval> = []
    private var rates: [Double] = []

    init(_ base: SampleBufferAudioOutput) {
        self.base = base
    }

    func enqueue(_ samples: [Float], format: PCMFormat, at time: TimeInterval) throws {
        let enqueue = Enqueue(
            time: time, firstFrame: Int64((samples[1] * 16_777_216).rounded()),
            frameCount: Int64(samples.count / format.channelCount)
        )
        lock.withLock { allRuns[allRuns.count - 1].enqueues.append(enqueue) }
        try base.enqueue(samples, format: format, at: time)
    }

    func flush() {
        lock.withLock {
            if allRuns[allRuns.count - 1].enqueues.isEmpty {
                allRuns[allRuns.count - 1].autoFlushTime = pendingAutoFlush
            } else {
                allRuns.append(Run(autoFlushTime: pendingAutoFlush))
            }
            pendingAutoFlush = nil
        }
        base.flush()
    }

    func setRate(_ rate: Double, at time: TimeInterval?) {
        lock.withLock { rates.append(rate) }
        base.setRate(rate, at: time)
    }

    func currentTime() -> TimeInterval {
        let time = base.currentTime()
        lock.withLock { readings.append(time) }
        return time
    }

    var outputLatency: TimeInterval {
        let latency = base.outputLatency
        lock.withLock { _ = latencyReadings.insert(latency) }
        return latency
    }

    var isReadyForMoreData: Bool { base.isReadyForMoreData }

    func setEventHandler(_ handler: @escaping @Sendable (AudioOutputEvent) -> Void) {
        base.setEventHandler { [weak self, base] event in
            if case let .autoFlushed(at: time) = event, let self {
                let clock = base.currentTime()
                self.lock.withLock {
                    self.autoFlushes.append((time, clock))
                    self.pendingAutoFlush = min(self.pendingAutoFlush ?? time, time)
                }
            }
            handler(event)
        }
    }

    var runs: [Run] { lock.withLock { allRuns.filter { !$0.enqueues.isEmpty } } }
    var clockReadings: [TimeInterval] { lock.withLock { readings } }
    var latencies: [TimeInterval] { lock.withLock { latencyReadings.sorted() } }

    func summary() -> String {
        lock.withLock {
            let flushes = autoFlushes.map { "flush time \($0.at) at clock \($0.clock) (\($0.at - $0.clock) s)" }
            return "\(autoFlushes.count) auto-flushes [\(flushes.joined(separator: ", "))], "
                + "\(allRuns.filter { !$0.enqueues.isEmpty }.count) runs, rates \(rates), latencies \(latencyReadings.sorted())"
        }
    }
}

/// Transport events with expectations fulfilled by the first matching one, recorded or to come.
private final class EventLog: @unchecked Sendable {
    struct Entry {
        var event: TransportEvent<String>
        var at: TimeInterval

        var status: TransportStatus? { if case let .status(status) = event { status } else { nil } }
        var frame: Int64? { if case let .position(_, frame, _) = event { frame } else { nil } }
    }

    private let lock = NSLock()
    private let start = Date()
    private var entries: [Entry] = []
    private var pending: [(match: (Entry) -> Bool, expectation: XCTestExpectation)] = []

    func append(_ event: TransportEvent<String>) {
        let entry = Entry(event: event, at: Date().timeIntervalSince(start))
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
        let met = lock.withLock {
            if entries.contains(where: match) { return true }
            pending.append((match, expectation))
            return false
        }
        if met { expectation.fulfill() }
        return expectation
    }

    var positions: [Int64] { lock.withLock { entries.compactMap(\.frame) } }

    func timing(from: TransportStatus, to: TransportStatus) -> TimeInterval {
        lock.withLock {
            (entries.last { $0.status == to }?.at ?? .nan) - (entries.first { $0.status == from }?.at ?? .nan)
        }
    }
}

private final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = 0
    private var observer: (any NSObjectProtocol)?

    init(_ name: Notification.Name) {
        observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            self?.lock.withLock { self?.fired += 1 }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var count: Int { lock.withLock { fired } }
}

private func defaultOutputDevice() -> AudioObjectID? {
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    return status == noErr && device != kAudioObjectUnknown ? device : nil
}

/// BlackHole if installed, since it is silent and always there on a test Mac; otherwise any other
/// output device Core Audio lists that answers. Skips when there is none.
private func otherOutputDevice() throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    var devices: [AudioObjectID] = []
    if AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr {
        devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        if AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) != noErr { devices = [] }
    }

    let current = defaultOutputDevice()
    let outputs = devices.filter { $0 != current && hasOutputStreams($0) }
    let blackHole = outputs.filter { uniqueID($0) == "BlackHole2ch_UID" }
    guard let other = (blackHole + outputs).first(where: answersCoreAudio).flatMap(uniqueID) else {
        throw XCTSkip("no output device other than the default that answers Core Audio")
    }
    return other
}

/// A wedged HAL driver (seen with BlackHole after the Mac idled, until coreaudiod restarts) blocks
/// every IOProc call for coreaudiod's 60 s IPC timeout, and the renderer's first enqueue with it.
private func answersCoreAudio(_ device: AudioObjectID) -> Bool {
    let answered = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        var proc: AudioDeviceIOProcID?
        if AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil, { _, _, _, _, _ in }) == noErr, let proc {
            AudioDeviceDestroyIOProcID(device, proc)
        }
        answered.signal()
    }
    return answered.wait(timeout: .now() + 2) == .success
}

private func hasOutputStreams(_ device: AudioObjectID) -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
}

private func uniqueID(_ device: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )
    var uid: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
    return uid?.takeRetainedValue() as String?
}
#endif
