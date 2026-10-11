import AVFoundation

/// The unattended tests. Mic-measured ones play a 1 kHz tone (no clicks, which would read as envelope
/// changes) through the speaker under .playAndRecord/.measurement and judge the recording.
enum AutoProbes {
    static let all: [AutoRun.Test] = [
        formatChange(id: "Q1a", preferred: nil),
        formatChange(id: "Q1b", preferred: 48000),
        AutoRun.Test(id: "Q2", question: "clock vs heard click, speaker", timeout: 40, needsMic: true, run: clockAlignment),
        AutoRun.Test(id: "Q3", question: "route changes and interruptions in code", timeout: 120, needsMic: false, run: routeChanges),
        rateChange(id: "Q4a", .spectral),
        rateChange(id: "Q4b", .timeDomain),
        feedMode(id: "Q5a", .whenReady),
        feedMode(id: "Q5b", .depth(2)),
        gap(id: "Q6a", hole: true),
        gap(id: "Q6b", hole: false),
        AutoRun.Test(id: "C", question: "control: Q4a and Q6a under .playback, no mic", timeout: 60, needsMic: false, run: control),
        AutoRun.Test(id: "Q7", question: "flush / setRate / player.stop cost, main vs background", timeout: 150, needsMic: false, run: cost),
    ]

    static let tone = Signals.sine(1000, 0.5)

    /// The measured run's renderer-side numbers, for the control to compare against.
    nonisolated(unsafe) static var measured: [String: [String: Any]] = [:]

    static func counts(since t: Double) -> [String: Int] {
        Events.shared.since(t).reduce(into: [:]) { $0[$1.kind, default: 0] += 1 }
    }

    static func waitClock(_ rig: Rig, _ media: Double, cap: Double) async throws {
        let wall = Log.shared.now
        while rig.now < media, Log.shared.now - wall < cap { try await pause(0.02) }
    }

    static func verdict(_ glitch: [String: Any], pass: Bool, _ text: String) -> [String: Any] {
        if let snr = glitch["snrDb"] as? Double, snr < 20 {
            return ["status": "inconclusive", "verdict": "tone only \(fmt(snr, 1)) dB over room noise; volume up? \(text)"]
        }
        if glitch["error"] != nil { return ["status": "error", "verdict": "\(glitch["error"]!)"] }
        return ["status": pass ? "pass" : "fail", "verdict": text]
    }

    static func formatChange(id: String, preferred: Double?) -> AutoRun.Test {
        AutoRun.Test(id: id, question: "Q1 glitch at format joins, preferred \(preferred.map { fmt($0, 0) } ?? "unset")", timeout: 45, needsMic: true) {
            try Session.configureMeasurement(preferredRate: preferred)
            let formats: [(rate: Double, channels: Int)] = [(44100, 1), (48000, 2), (96000, 2), (192000, 2), (44100, 1)]
            let segments = formats.enumerated().map { Segment(pts: Double($0.offset) * 3, duration: 3, rate: $0.element.rate, channels: $0.element.channels) }
            let joins = [3.0, 6, 9, 12]
            let start = Log.shared.now
            let take = try await Take.begin(Rig(Feeder(segments, tone)), feed: .depth(3))
            defer { take.end() }
            var rates: Set<Double> = [Session.shared.sampleRate]
            let wall = Log.shared.now
            while take.rig.now < 14.8, Log.shared.now - wall < 25 {
                try await pause(0.05)
                rates.insert(Session.shared.sampleRate)
            }
            let glitch = take.glitches(media: 0.5, 14.6, around: joins)
            let near = (glitch["dipsNearMarks"] as? Int ?? 0) + (glitch["phaseJumpsNearMarks"] as? Int ?? 0)
            return verdict(glitch, pass: near == 0, "\(near) dips/phase jumps within 0.35 s of the joins")
                .merging(["category": Session.category, "glitch": glitch, "hwRates": rates.sorted(), "events": counts(since: start), "state": take.rig.state]) { a, _ in a }
        }
    }

    /// Clicks at whole media seconds; each one's onset in the mic against the host time `currentTime()` reached it.
    @Sendable static func clockAlignment() async throws -> [String: Any] {
        try Session.configureMeasurement()
        let take = try await Take.begin(Rig(Signals.stream(Signals.click)), feed: .whenReady)
        defer { take.end() }
        try await waitClock(take.rig, 12.6, cap: 20)
        var delays: [Double] = []
        for k in 2...12 {
            guard let expected = take.trace.host(at: Double(k)), let chunk = take.mic.chunk(from: expected - 0.15, to: expected + 0.35) else { continue }
            let from = max(1, Int(((expected - 0.15 - chunk.hostStart) * chunk.rate).rounded()))
            let to = min(chunk.samples.count, Int(((expected + 0.35 - chunk.hostStart) * chunk.rate).rounded()))
            guard to > from + 10 else { continue }
            let edge = (from..<to).map { abs(chunk.samples[$0] - chunk.samples[$0 - 1]) }
            let floor = Double(median(edge.map(Double.init)))
            let peak = Double(edge.max() ?? 0)
            guard peak > 10 * floor, let onset = edge.firstIndex(where: { Double($0) > 0.3 * peak }) else { continue }
            delays.append(chunk.hostStart + Double(from + onset) / chunk.rate - expected)
        }
        let session = Session.shared
        let raw = median(delays)
        let corrected = raw - session.inputLatency
        let metrics: [String: Any] = [
            "category": Session.category, "rawDelaysMs": delays.map { round3($0 * 1000) }, "rawMedianMs": round3(raw * 1000),
            "inputLatencyMs": round3(session.inputLatency * 1000), "outputLatencyMs": round3(session.outputLatency * 1000),
            "ioBufferMs": round3(session.ioBufferDuration * 1000), "heardMinusClockMs": round3(corrected * 1000),
            "heardMinusClockMinusOutputLatencyMs": round3((corrected - session.outputLatency) * 1000),
        ]
        guard delays.count >= 5 else { return ["status": "inconclusive", "verdict": "only \(delays.count) clicks detected"].merging(metrics) { a, _ in a } }
        let spread = (delays.max()! - delays.min()!) * 1000
        return ["status": "pass", "verdict": "click heard \(fmt(corrected * 1000, 1)) ms after currentTime() reached it (after inputLatency), outputLatency \(fmt(session.outputLatency * 1000, 1)) ms, spread \(fmt(spread, 1)) ms over \(delays.count)"]
            .merging(metrics) { a, _ in a }
    }

    @Sendable static func routeChanges() async throws -> [String: Any] {
        let session = Session.shared
        try? session.setActive(false)
        // No .defaultToSpeaker, so the default route is the receiver and the speaker override is a real change.
        try session.setCategory(.playAndRecord, mode: .default, options: [])
        try session.setActive(true)
        Log.shared.write("session .playAndRecord (receiver): \(Session.snapshot)")
        let rig = Rig(Signals.stream(tone))
        defer { rig.stop() }
        try await rig.start(.depth(2))
        try await pause(1.5)
        var steps: [[String: Any]] = []
        func step(_ name: String, settle: Double = 3, _ action: () throws -> Void) async throws {
            let (t, media, wall) = (Log.shared.now, rig.now, Log.shared.now)
            var error: String?
            do { try action() } catch let thrown { error = "\(thrown)" }
            try await pause(settle)
            let advanced = rig.now - media
            let events = Events.shared.since(t)
            steps.append([
                "step": name, "error": error ?? NSNull(), "events": Events.json(events, from: t),
                "hwRate": session.sampleRate, "outputs": Session.outputs, "category": Session.category,
                "rate": rig.synchronizer.rate, "mediaPerWall": round3(advanced / (Log.shared.now - wall)), "state": rig.state,
            ])
            Log.shared.write("step \(name): error=\(error ?? "none") events=\(events.map(\.kind)) media/wall \(fmt(advanced / (Log.shared.now - wall))) \(Session.snapshot)")
        }
        try await step("override .speaker") { try session.overrideOutputAudioPort(.speaker) }
        try await step("override .none") { try session.overrideOutputAudioPort(.none) }
        try await step("category -> .playback") { try session.setCategory(.playback, mode: .default, options: []) }
        try await step("category -> .playAndRecord") { try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker]) }
        try await step("setActive(false)", settle: 1) { try session.setActive(false) }
        try await step("setActive(true)") { try session.setActive(true) }
        for rate in [44100.0, 48000, 96000] {
            try await step("setPreferredSampleRate(\(Int(rate)))") { try session.setPreferredSampleRate(rate) }
        }
        let alive = (steps.last?["mediaPerWall"] as? Double ?? 0) > 0.9
        let flushes = steps.reduce(0) { $0 + (($1["events"] as? [[String: Any]])?.filter { $0["kind"] as? String == "autoFlush" }.count ?? 0) }
        return ["status": alive ? "pass" : "fail", "verdict": "\(flushes) auto-flushes over \(steps.count) steps; playing at the end: \(alive)", "steps": steps]
    }

    /// 3 s at 1x, 4 s at 2x, 3 s at 1x; the renderer-side numbers, shared with the control.
    static func rateCycle(_ rig: Rig) async throws -> (metrics: [String: Any], marks: [Double]) {
        var marks: [Double] = [], ratios: [Double] = [], took: [Double] = [], advanced: [Double] = []
        func span(_ seconds: Double) async throws {
            let (wall, media) = (Log.shared.now, rig.now)
            try await pause(seconds)
            ratios.append(round3((rig.now - media) / (Log.shared.now - wall)))
        }
        func change(to rate: Float) async throws {
            let media = rig.now
            marks.append(media)
            took.append(round3(milliseconds { rig.synchronizer.rate = rate }))
            try await pause(0.05)
            advanced.append(round3((rig.now - media) * 1000))
        }
        try await span(3)
        try await change(to: 2)
        try await span(4)
        try await change(to: 1)
        try await span(3)
        return (["mediaPerWall": ratios, "setRateMs": took, "mediaMsInNext50ms": advanced], marks)
    }

    static func rateChange(id: String, _ algorithm: AVAudioTimePitchAlgorithm) -> AutoRun.Test {
        AutoRun.Test(id: id, question: "Q4 dropout at rate 1 -> 2 -> 1, \(algorithm.rawValue)", timeout: 40, needsMic: true) {
            try Session.configureMeasurement()
            let start = Log.shared.now
            let take = try await Take.begin(Rig(Signals.stream(tone), algorithm: algorithm), feed: .depth(3))
            defer { take.end() }
            let (metrics, marks) = try await rateCycle(take.rig)
            let end = take.rig.now
            let glitch = take.glitches(media: 0.5, end - 0.2, around: marks)
            let dips = glitch["dipsNearMarks"] as? Int ?? 0
            let events = counts(since: start)
            measured[id] = metrics.merging(["events": events]) { a, _ in a }
            return verdict(glitch, pass: dips == 0, "\(dips) dips and \(glitch["phaseJumpsNearMarks"] ?? 0) phase jumps within 0.35 s of the rate changes")
                .merging(["category": Session.category, "glitch": glitch, "renderer": metrics, "events": events]) { a, _ in a }
        }
    }

    static func feedMode(id: String, _ feed: Rig.Feed) -> AutoRun.Test {
        let mode: String
        if case .depth(let target) = feed { mode = "\(Int(target)) s target depth" } else { mode = "requestMediaDataWhenReady (default 1 s pull)" }
        return AutoRun.Test(id: id, question: "Q5 glitches over 40 s, \(mode)", timeout: 70, needsMic: true) {
            try Session.configureMeasurement()
            let start = Log.shared.now
            let take = try await Take.begin(Rig(Signals.stream(tone)), feed: feed)
            defer { take.end() }
            try await waitClock(take.rig, 40.5, cap: 50)
            let glitch = take.glitches(media: 0.5, 40.3)
            let dips = (glitch["dips"] as? [Any])?.count ?? 0
            let jumps = glitch["phaseJumps"] as? Int ?? 0
            return verdict(glitch, pass: dips + jumps == 0, "\(dips) dips, \(jumps) phase jumps in 40 s")
                .merging(["category": Session.category, "glitch": glitch, "events": counts(since: start), "state": take.rig.state]) { a, _ in a }
        }
    }

    /// 1 kHz stamped 0-3 s, then 2 kHz stamped 4-7 s (hole) or 2.5-5.5 s (overlap).
    static func gapRig(hole: Bool) -> Rig {
        let second = Signals.sine(2000, 0.5)
        let signal: Signal = { t, channel, segment in segment == 0 ? tone(t, channel, 0) : second(t, channel, segment) }
        return Rig(Feeder([Segment(pts: 0, duration: 3, rate: 44100, channels: 2), Segment(pts: hole ? 4 : 2.5, duration: 3, rate: 44100, channels: 2)], signal))
    }

    static func gap(id: String, hole: Bool) -> AutoRun.Test {
        AutoRun.Test(id: id, question: hole ? "Q6 PTS hole 3-4 s: silence or butt-join" : "Q6 PTS overlap 2.5-3 s: dropped, mixed or shifted", timeout: 30, needsMic: true) {
            try Session.configureMeasurement()
            let start = Log.shared.now
            let take = try await Take.begin(gapRig(hole: hole), feed: .depth(8))
            defer { take.end() }
            let wall = Log.shared.now
            try await pause(9)
            let clockAfter9s = take.rig.now
            guard let a = take.trace.host(at: 0.05), let chunk = take.mic.chunk(from: a, to: wall + 9) else {
                return ["status": "error", "verdict": "no clock or recording"]
            }
            let first = Tone(chunk, hz: 1000, from: a - 0.3, to: hostNow())
            let second = Tone(chunk, hz: 2000, from: a - 0.3, to: hostNow())
            let loud = { (t: Tone) in t.amplitude.sorted()[Int(Double(t.amplitude.count) * 0.9)] }
            guard let one = first.span(loud: loud(first)), let two = second.span(loud: loud(second)) else {
                return ["status": "inconclusive", "verdict": "a tone was not found in the recording"]
            }
            let gap = two.on - one.off
            let (dur1, dur2) = (one.off - one.on, two.off - two.on)
            let text: String
            if hole {
                text = gap > 0.9 ? "silence present, gap \(fmt(gap)) s (hole honoured)" : gap < 0.1 ? "butt-joined, gap \(fmt(gap)) s" : "partial gap \(fmt(gap)) s"
            } else if gap < -0.4 {
                text = "both played: 2 kHz starts \(fmt(-gap)) s before 1 kHz ends (mixed)"
            } else {
                text = "gap \(fmt(gap)) s; second segment lasts \(fmt(dur2)) s (2.5 = overlap dropped, 3.0 = shifted later)"
            }
            measured[id] = ["clockAfter9s": round3(clockAfter9s), "events": counts(since: start)]
            return [
                "status": "pass", "verdict": text, "category": Session.category,
                "gapS": round3(gap), "firstToneS": round3(dur1), "secondToneS": round3(dur2),
                "secondOnsetVsClockS": round3(two.on - (take.trace.host(at: hole ? 4 : 2.5) ?? .nan)),
                "clockAfter9s": round3(clockAfter9s), "noiseDb": round3(db(take.noise)), "levelDb": round3(db(loud(first))),
                "events": counts(since: start), "state": take.rig.state,
            ]
        }
    }

    /// Q4a's rate cycle and Q6a's hole again under .playback with no mic, compared on renderer-side numbers.
    @Sendable static func control() async throws -> [String: Any] {
        try Session.configure(longForm: false)
        var rate: [String: Any] = [:]
        var start = Log.shared.now
        do {
            let rig = Rig(Signals.stream(tone), algorithm: .spectral)
            defer { rig.stop() }
            try await rig.start(.depth(3))
            rate = try await rateCycle(rig).metrics
            rate["events"] = counts(since: start)
        }
        start = Log.shared.now
        var hole: [String: Any] = [:]
        do {
            let rig = gapRig(hole: true)
            defer { rig.stop() }
            try await rig.start(.depth(8))
            try await pause(9)
            hole = ["clockAfter9s": round3(rig.now), "events": counts(since: start)]
        }
        let reference = measured["Q4a"]?["mediaPerWall"] as? [Double] ?? []
        let ratios = rate["mediaPerWall"] as? [Double] ?? []
        let sameClock = reference.count == ratios.count && zip(reference, ratios).allSatisfy { abs($0 - $1) < 0.03 }
        let flushes = { (m: [String: Any]?) in (m?["events"] as? [String: Int])?["autoFlush"] ?? 0 }
        let sameFlushes = flushes(rate) == flushes(measured["Q4a"]) && flushes(hole) == flushes(measured["Q6a"])
        let same = sameClock && sameFlushes
        return [
            "status": reference.isEmpty ? "inconclusive" : same ? "pass" : "fail",
            "verdict": reference.isEmpty ? "no measured Q4a to compare" : "media/wall \(ratios) vs \(reference) under playAndRecord; auto-flushes match: \(sameFlushes)",
            "category": Session.category, "rateCycle": rate, "hole": hole,
            "measuredRateCycle": measured["Q4a"] ?? NSNull(), "measuredHole": measured["Q6a"] ?? NSNull(),
        ]
    }

    /// Times `body` on the main thread or a background queue.
    static func timed(main: Bool, _ body: @escaping @Sendable () -> Void) async -> Double {
        if main { return await MainActor.run { milliseconds(body) } }
        return await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: milliseconds(body)) }
        }
    }

    @Sendable static func cost() async throws -> [String: Any] {
        try Session.configure(longForm: false)
        func summary(_ values: [Double]) -> [String: Any] {
            let sorted = values.sorted()
            return ["n": values.count, "minMs": round3(sorted.first ?? 0), "medianMs": round3(median(values)), "maxMs": round3(sorted.last ?? 0)]
        }
        var out: [String: Any] = [:]
        for main in [true, false] {
            let thread = main ? "main" : "background"
            let rig = Rig(Signals.stream(tone))
            defer { rig.stop() }
            try await rig.start(.depth(3))
            try await pause(1)
            var flushes: [Double] = [], toTwo: [Double] = [], toOne: [Double] = []
            for _ in 0..<6 {
                flushes.append(await timed(main: main) { _ = rig.flushAndRefill() })
                try await pause(0.5)
                toTwo.append(await timed(main: main) { rig.synchronizer.rate = 2 })
                try await pause(0.5)
                toOne.append(await timed(main: main) { rig.synchronizer.rate = 1 })
                try await pause(0.5)
            }
            out["renderer.flush() \(thread)"] = summary(flushes)
            out["synchronizer.rate = 2 \(thread)"] = summary(toTwo)
            out["synchronizer.rate = 1 \(thread)"] = summary(toOne)
            rig.stop()

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<2 {
                for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![channel][frame] = tone(Double(frame) / 44100, channel, 0) }
            }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()
            defer { engine.stop() }
            var stops: [Double] = []
            for _ in 0..<6 {
                player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
                player.play()
                try await pause(0.6)
                stops.append(await timed(main: main) { player.stop() })
                try await pause(0.3)
            }
            out["AVAudioPlayerNode.stop() \(thread)"] = summary(stops)
        }
        let flush = (out["renderer.flush() main"] as? [String: Any])?["medianMs"] ?? "?"
        let stop = (out["AVAudioPlayerNode.stop() main"] as? [String: Any])?["medianMs"] ?? "?"
        return ["status": "pass", "verdict": "median on main: flush \(flush) ms, player.stop \(stop) ms", "category": Session.category, "timings": out]
    }
}
