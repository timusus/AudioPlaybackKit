import AVFoundation
import CoreMedia
import QuartzCore

/// Notifications as data, so an unattended test can count what fired inside a time window.
final class Events: @unchecked Sendable {
    static let shared = Events()
    struct Event { let t: Double; let kind: String; let detail: String }
    private let lock = NSLock()
    private var all: [Event] = []

    func add(_ kind: String, _ detail: String) { lock.withLock { all.append(Event(t: Log.shared.now, kind: kind, detail: detail)) } }

    func since(_ t: Double) -> [Event] { lock.withLock { all.filter { $0.t >= t } } }

    static func json(_ events: [Event], from origin: Double) -> [[String: Any]] {
        events.map { ["t": round3($0.t - origin), "kind": $0.kind, "detail": $0.detail] }
    }
}

func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

/// Host time in seconds, the base of both `AVAudioTime.hostTime` and the clock trace.
func hostNow() -> Double { CACurrentMediaTime() }

/// (host, media) pairs from `currentTime()` every 5 ms, so a media time maps to the host time the
/// synchronizer's clock said it was presenting it.
final class ClockTrace: @unchecked Sendable {
    private let queue = DispatchQueue(label: "renderprobe.clock", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var pairs: [(host: Double, media: Double)] = []

    init(_ synchronizer: AVSampleBufferRenderSynchronizer) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.005, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            let media = synchronizer.currentTime().seconds
            let host = hostNow()
            self?.lock.withLock { self?.pairs.append((host, media)) }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() { timer?.cancel() }

    /// First host time at which the clock reached `media`, interpolated between polls.
    func host(at media: Double) -> Double? {
        lock.withLock {
            guard let i = pairs.firstIndex(where: { $0.media >= media }), i > 0 else { return nil }
            let (a, b) = (pairs[i - 1], pairs[i])
            guard b.media > a.media else { return b.host }
            return a.host + (media - a.media) / (b.media - a.media) * (b.host - a.host)
        }
    }
}

/// Mono mic capture with the host time of every tap buffer; a format change restarts the tap as a new chunk.
final class MicRecorder: @unchecked Sendable {
    struct Chunk { var hostStart: Double; let rate: Double; var samples: [Float] }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var chunks: [Chunk] = []
    private var observer: NSObjectProtocol?
    private(set) var restarts = 0

    func start() throws {
        _ = engine.mainMixerNode
        installTap()
        engine.prepare()
        try engine.start()
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            Log.shared.write("mic engine configuration change; restarting tap at \(fmt(Session.shared.sampleRate, 0)) Hz")
            Events.shared.add("micEngineConfigurationChange", "hwRate=\(fmt(Session.shared.sampleRate, 0))")
            restarts += 1
            engine.inputNode.removeTap(onBus: 0)
            installTap()
            try? engine.start()
        }
        Log.shared.write("mic recording at \(fmt(engine.inputNode.outputFormat(forBus: 0).sampleRate, 0)) Hz, inputLatency \(fmt(Session.shared.inputLatency * 1000, 1)) ms")
    }

    func stop() {
        observer.map(NotificationCenter.default.removeObserver)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// The longest chunk as a WAV in Documents, so a verdict can be checked by ear or on the Mac.
    func save(as name: String) {
        guard let chunk = lock.withLock({ chunks.max { $0.samples.count < $1.samples.count } }), !chunk.samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: chunk.rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.samples.count)) else { return }
        buffer.frameLength = buffer.frameCapacity
        chunk.samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: chunk.samples.count) }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        } catch {
            Log.shared.write("mic save failed: \(error)")
        }
    }

    /// The chunk that covers most of [from, to] in host time.
    func chunk(from: Double, to: Double) -> Chunk? {
        lock.withLock {
            chunks.max { overlap($0, from, to) < overlap($1, from, to) }
        }
    }

    private func overlap(_ c: Chunk, _ from: Double, _ to: Double) -> Double {
        min(to, c.hostStart + Double(c.samples.count) / c.rate) - max(from, c.hostStart)
    }

    private func installTap() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        lock.withLock { chunks.append(Chunk(hostStart: 0, rate: format.sampleRate, samples: [])) }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            guard let self, let data = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            lock.withLock {
                let last = self.chunks.count - 1
                if self.chunks[last].samples.isEmpty {
                    self.chunks[last].hostStart = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : hostNow()
                }
                self.chunks[last].samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: count))
            }
        }
    }
}

/// Amplitude and phase of one frequency in 1 ms blocks: a quadrature demodulator whose block is a whole
/// number of cycles at 1 and 2 kHz, so those two tones do not leak into each other.
struct Tone {
    let blockStart: Double
    let block: Double
    let amplitude: [Double]
    let phase: [Double]

    init(_ chunk: MicRecorder.Chunk, hz: Double, from: Double, to: Double) {
        let n = Int((chunk.rate / 1000).rounded())
        block = Double(n) / chunk.rate
        let first = max(0, Int(((from - chunk.hostStart) * chunk.rate).rounded()))
        let last = min(chunk.samples.count, Int(((to - chunk.hostStart) * chunk.rate).rounded()))
        blockStart = chunk.hostStart + Double(first) / chunk.rate
        var amplitude: [Double] = [], phase: [Double] = []
        var i = first
        while i + n <= last {
            var re = 0.0, im = 0.0
            for k in i..<(i + n) {
                let w = 2 * .pi * hz * Double(k) / chunk.rate
                re += Double(chunk.samples[k]) * cos(w)
                im -= Double(chunk.samples[k]) * sin(w)
            }
            amplitude.append(2 * sqrt(re * re + im * im) / Double(n))
            phase.append(atan2(im, re))
            i += n
        }
        self.amplitude = amplitude
        self.phase = phase
    }

    func host(_ index: Int) -> Double { blockStart + Double(index) * block }

    var reference: Double { median(amplitude) }

    /// Runs of blocks more than 6 dB under the median lasting 5 ms or more, as (host start, ms).
    func dips() -> [(host: Double, ms: Double)] {
        let floor = reference / 2
        var runs: [(Double, Double)] = []
        var start: Int?
        for (i, a) in (amplitude + [Double.infinity]).enumerated() {
            if a < floor { start = start ?? i; continue }
            if let s = start, Double(i - s) * block >= 0.005 { runs.append((host(s), Double(i - s) * block * 1000)) }
            start = nil
        }
        return runs
    }

    /// Phase steps over 1 rad between blocks whose phase is steady for 3 ms either side: a splice or a
    /// skipped/repeated span. Room noise in the band scrambles phase for a stretch, so it is not counted.
    func phaseJumps() -> [Double] {
        let floor = reference / 2
        let step = { (i: Int) -> Double in
            var d = phase[i] - phase[i - 1]
            d -= 2 * .pi * (d / (2 * .pi)).rounded()
            return abs(d)
        }
        guard amplitude.count > 7 else { return [] }
        return (4..<(amplitude.count - 3)).compactMap { i in
            guard amplitude[(i - 4)...(i + 2)].allSatisfy({ $0 > floor }), step(i) > 1 else { return nil }
            let steady = [i - 3, i - 2, i - 1, i + 1, i + 2].allSatisfy { step($0) < 0.3 }
            return steady ? host(i) : nil
        }
    }

    /// The longest stretch where the tone, smoothed over 20 ms, stands over half its loud level; one noisy
    /// block elsewhere in the recording cannot stretch it.
    func span(loud: Double) -> (on: Double, off: Double)? {
        let width = 20
        guard amplitude.count > width else { return nil }
        var sum = amplitude[0..<width].reduce(0, +)
        var best: (Int, Int)?
        var start: Int?
        for i in width...amplitude.count {
            let above = i < amplitude.count && sum / Double(width) > loud / 2
            if above { start = start ?? (i - width) } else if let s = start {
                if best.map({ i - s > $0.1 - $0.0 }) ?? true { best = (s, i) }
                start = nil
            }
            if i < amplitude.count { sum += amplitude[i] - amplitude[i - width] }
        }
        return best.map { (host($0.0 + width / 2), host($0.1 - width / 2)) }
    }
}

func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    return values.sorted()[values.count / 2]
}

func db(_ ratio: Double) -> Double { ratio > 0 ? 20 * log10(ratio) : -200 }

/// One mic-observed playback: a renderer rig, its clock trace and the recording, with a pre-roll of
/// room noise so the analysis can say whether the speaker was audible at all.
struct Take {
    let rig: Rig
    let mic: MicRecorder
    let trace: ClockTrace
    let noise: Double

    static func begin(_ rig: Rig, feed: Rig.Feed) async throws -> Take {
        let mic = MicRecorder()
        try mic.start()
        let quietFrom = hostNow()
        try await pause(0.6)
        let trace = ClockTrace(rig.synchronizer)
        try await rig.start(feed)
        let noise = mic.chunk(from: quietFrom + 0.1, to: quietFrom + 0.5).map { Tone($0, hz: 1000, from: quietFrom + 0.1, to: quietFrom + 0.5).reference } ?? 0
        return Take(rig: rig, mic: mic, trace: trace, noise: noise)
    }

    func end() {
        trace.stop()
        rig.stop()
        mic.stop()
        mic.save(as: "mic-\(AutoRun.current).wav")
    }

    /// Glitch report for a steady 1 kHz tone between two media times, mapped through the clock trace.
    func glitches(media from: Double, _ to: Double, around marks: [Double] = []) -> [String: Any] {
        guard let a = trace.host(at: from), let b = trace.host(at: to) ?? Optional(hostNow()), let chunk = mic.chunk(from: a, to: b) else {
            return ["error": "no clock or recording for media \(from)-\(to)"]
        }
        let tone = Tone(chunk, hz: 1000, from: a, to: b)
        let dips = tone.dips()
        let jumps = tone.phaseJumps()
        let markHosts = marks.compactMap { trace.host(at: $0) }
        let near = { (h: Double) in markHosts.contains { abs($0 - h) < 0.35 } }
        return [
            "levelDb": round3(db(tone.reference)), "snrDb": round3(db(tone.reference / max(noise, 1e-9))),
            "dips": dips.map { ["at": round3($0.host - a + from), "ms": round3($0.ms)] },
            "phaseJumps": jumps.count, "phaseJumpsAt": jumps.prefix(20).map { round3($0 - a + from) },
            "dipsNearMarks": dips.filter { near($0.host) }.count, "phaseJumpsNearMarks": jumps.filter(near).count,
            "micRestarts": mic.restarts,
        ]
    }
}
