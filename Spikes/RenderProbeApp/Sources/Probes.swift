import AVFoundation

struct Probe: Identifiable {
    let id: String
    let title: String
    /// What the owner should listen or look for; shown on screen while the test runs.
    let listen: String
    let run: @Sendable (Runner) async throws -> Void
}

enum Probes {
    static let all: [Probe] = [
        formatChange(id: "1a", preferred: nil),
        formatChange(id: "1b", preferred: 48000),
        airPlay,
        routeChanges,
        rateChange(id: "4a", .spectral),
        rateChange(id: "4b", .timeDomain),
        feedMode(id: "5a", .whenReady),
        feedMode(id: "5b", .depth(2)),
        gap(id: "6a", hole: true),
        gap(id: "6b", hole: false),
        cost,
    ]

    private static let steady = Signals.mix(Signals.sine(440), Signals.click)

    static func formatChange(id: String, preferred: Double?) -> Probe {
        let rate = preferred.map { "setPreferredSampleRate(\(Int($0)))" } ?? "no preferred rate"
        return Probe(
            id: id, title: "Q1 format change, \(rate)",
            listen: """
            440 Hz tone with a click each second; a 0.2 s rising chirp straddles each join at 3, 6, 9, 12 s.
            Formats: 44.1k mono | 48k stereo | 96k stereo | 192k stereo | 44.1k mono.
            Listen for a pop, gap, pitch shift or stutter inside a chirp. The log shows the hardware rate at each join.
            """
        ) { runner in
            try Session.configure(longForm: false, preferredRate: preferred)
            let formats: [(rate: Double, channels: Int)] = [(44100, 1), (48000, 2), (96000, 2), (192000, 2), (44100, 1)]
            let segments = formats.enumerated().map { Segment(pts: Double($0.offset) * 3, duration: 3, rate: $0.element.rate, channels: $0.element.channels) }
            let joins = [3.0, 6, 9, 12]
            let rig = Rig(Feeder(segments, Signals.mix(steady, Signals.chirps(at: joins))))
            defer { rig.stop() }
            await runner.show(rig)
            try await rig.start(.depth(3))
            var last = Session.shared.sampleRate
            var next = 0
            let deadline = Log.shared.now + 25
            while rig.now < 15.2, Log.shared.now < deadline {
                try await pause(0.05)
                let hardware = Session.shared.sampleRate
                if hardware != last {
                    Log.shared.write("HARDWARE RATE \(fmt(last, 0)) -> \(fmt(hardware, 0)) at media \(fmt(rig.now))")
                    last = hardware
                }
                if next < joins.count, rig.now >= joins[next] + 0.3 {
                    let format = formats[next + 1]
                    Log.shared.write("past join \(fmt(joins[next], 1)) s, now \(Int(format.rate)) Hz x\(format.channels): \(Session.snapshot) \(rig.state)")
                    next += 1
                }
            }
            Log.shared.write("done: \(rig.state)")
        }
    }

    static let airPlay = Probe(
        id: "2", title: "Q2 AirPlay 2, .longFormAudio",
        listen: """
        First pick the AirPlay speaker with the route button, then start. Keep screen on.
        A click sounds at every whole second of the clock. Compare: does the click you hear coincide with the clock showing x.000?
        Tap TAP when you hear a click; the log records the clock at the tap. Note by ear how late or early the click is.
        The log shows start latency, how far ahead the renderer pulls, and the pull cadence.
        """
    ) { runner in
        try Session.configure(longForm: true)
        let rig = Rig(Signals.stream(Signals.mix(Signals.click, Signals.sine(220, 0.05))))
        defer { rig.stop() }
        await runner.show(rig)
        Log.shared.write("start requested; wall clock is the left column")
        try await rig.start(.whenReady)
        try await pause(300)
    }

    static let routeChanges = Probe(
        id: "3", title: "Q3 route changes and interruptions",
        listen: """
        A tone with clicks plays for up to 20 minutes. Do these in turn, a few seconds apart, and note each in the log:
        unplug/plug headphones (or USB-C), connect/disconnect Bluetooth, pick AirPlay then back to the phone,
        call the phone and decline, trigger Siri. ROUTE CHANGE, INTERRUPTION and AUTO-FLUSH lines appear as they happen.
        """
    ) { runner in
        try Session.configure(longForm: false)
        let rig = Rig(Signals.stream(steady))
        Session.onResume = { rig.resume() }
        defer {
            Session.onResume = nil
            rig.stop()
        }
        await runner.show(rig)
        try await rig.start(.depth(2))
        try await pause(1200)
    }

    static func rateChange(id: String, _ algorithm: AVAudioTimePitchAlgorithm) -> Probe {
        Probe(
            id: id, title: "Q4 rate 1 -> 2 -> 1, \(algorithm.rawValue)",
            listen: """
            440 Hz tone with a click each second, two cycles of 3 s at 1x, 4 s at 2x, 3 s at 1x.
            At 2x the clicks come twice as fast and the tone should keep its pitch.
            Listen for a short dropout (about 60 ms) at each rate change. The log shows any AUTO-FLUSH and the media/wall ratio.
            """
        ) { runner in
            try Session.configure(longForm: false)
            let rig = Rig(Signals.stream(steady), algorithm: algorithm)
            defer { rig.stop() }
            await runner.show(rig)
            try await rig.start(.depth(3))
            func span(_ label: String, _ seconds: Double) async throws {
                let (wall, media) = (Log.shared.now, rig.now)
                try await pause(seconds)
                Log.shared.write("\(label): media/wall \(fmt((rig.now - media) / (Log.shared.now - wall))) clock \(fmt(rig.now))")
            }
            func change(to rate: Float) async throws {
                let media = rig.now
                let took = milliseconds { rig.synchronizer.rate = rate }
                try await pause(0.05)
                Log.shared.write("rate = \(rate) took \(fmt(took, 2)) ms; media advanced \(fmt((rig.now - media) * 1000, 0)) ms in the next 50 ms")
            }
            for _ in 0..<2 {
                try await span("1x", 3)
                try await change(to: 2)
                try await span("2x", 4)
                try await change(to: 1)
            }
            try await span("1x", 3)
            Log.shared.write("done: \(rig.state)")
        }
    }

    static func feedMode(id: String, _ feed: Rig.Feed) -> Probe {
        let mode: String
        if case .depth(let target) = feed { mode = "feed to \(Int(target)) s depth" } else { mode = "requestMediaDataWhenReady only" }
        return Probe(
            id: id, title: "Q5 \(mode)",
            listen: """
            A steady tone with a click each second for 2 minutes. Listen for a dropout, tick or stutter about once a second
            (the default feed refills once a second). Also try scrolling this log and locking the screen for a while.
            Run 5a and 5b back to back and say which is cleaner. The log shows the queue depth range and feeds per second.
            """
        ) { runner in
            try Session.configure(longForm: false)
            let rig = Rig(Signals.stream(steady))
            defer { rig.stop() }
            await runner.show(rig)
            try await rig.start(feed)
            try await pause(120)
            Log.shared.write("done: \(rig.state)")
        }
    }

    static func gap(id: String, hole: Bool) -> Probe {
        let name = hole ? "PTS hole" : "PTS overlap"
        let listen = hole
            ? """
            440 Hz for media 0-3 s, then the next buffers are stamped 4-7 s (660 Hz). Clicks at whole seconds.
            Silence from 3.0 to 4.0 on the clock, with the next click exactly at 4.0 = the hole is honoured.
            660 Hz starting right at 3.0 with its click at 3.0 = butt-joined, one second early.
            """
            : """
            440 Hz for media 0-3 s, then the next buffers are stamped 2.5-5.5 s (880 Hz).
            880 Hz starting at 3.0 and ending at 5.5 = the overlap was dropped (the first 0.5 s of 880 lost).
            880 Hz starting at 2.5, mixed with 440 until 3.0 = both played. Clicks at whole seconds.
            """
        return Probe(id: id, title: "Q6 \(name)", listen: listen) { runner in
            try Session.configure(longForm: false)
            let second = Segment(pts: hole ? 4 : 2.5, duration: 3, rate: 44100, channels: 2)
            let (first, later) = (Signals.sine(440), Signals.sine(hole ? 660 : 880))
            let tone: Signal = { t, channel, segment in segment == 0 ? first(t, channel, 0) : later(t, channel, segment) }
            let signal = Signals.mix(Signals.click, tone)
            let rig = Rig(Feeder([Segment(pts: 0, duration: 3, rate: 44100, channels: 2), second], signal))
            defer { rig.stop() }
            await runner.show(rig)
            try await rig.start(.depth(8))
            let wall = Log.shared.now
            while rig.now < 8.2, Log.shared.now - wall < 15 {
                try await pause(0.5)
                Log.shared.write("clock \(fmt(rig.now)) \(rig.state)")
            }
            Log.shared.write("done")
        }
    }

    static let cost = Probe(
        id: "7", title: "Q7 flush / setRate cost vs AVAudioPlayerNode.stop()",
        listen: """
        Plays a tone while it times each call on a background thread. Expect a few short interruptions of the tone;
        nothing to judge by ear. Takes about 1 minute; the log has every sample in ms and a min / median / max line.
        """
    ) { runner in
        try Session.configure(longForm: false)
        func summary(_ label: String, _ values: [Double]) {
            let sorted = values.sorted()
            Log.shared.write("\(label): n=\(values.count) min \(fmt(sorted.first ?? 0, 2)) median \(fmt(sorted[sorted.count / 2], 2)) max \(fmt(sorted.last ?? 0, 2)) ms")
        }
        do {
            let rig = Rig(Signals.stream(steady))
            defer { rig.stop() }
            await runner.show(rig)
            try await rig.start(.depth(3))
            try await pause(1.5)
            var flushes: [Double] = [], toTwo: [Double] = [], toOne: [Double] = [], seeks: [Double] = []
            for _ in 0..<8 {
                flushes.append(rig.flushAndRefill())
                try await pause(0.7)
                toTwo.append(milliseconds { rig.synchronizer.rate = 2 })
                try await pause(0.7)
                toOne.append(milliseconds { rig.synchronizer.rate = 1 })
                try await pause(0.7)
                let at = rig.synchronizer.currentTime()
                seeks.append(milliseconds { rig.synchronizer.setRate(1, time: at) })
                try await pause(0.7)
            }
            summary("renderer.flush()", flushes)
            summary("synchronizer.rate = 2", toTwo)
            summary("synchronizer.rate = 1", toOne)
            summary("synchronizer.setRate(1, time: now)", seeks)
        }
        for withTimePitch in [false, true] {
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
            let tone = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 3)!
            tone.frameLength = tone.frameCapacity
            for channel in 0..<2 {
                for frame in 0..<Int(tone.frameLength) { tone.floatChannelData![channel][frame] = steady(Double(frame) / 44100, channel, 0) }
            }
            engine.attach(player)
            if withTimePitch {
                let timePitch = AVAudioUnitTimePitch()
                engine.attach(timePitch)
                engine.connect(player, to: timePitch, format: format)
                engine.connect(timePitch, to: engine.mainMixerNode, format: format)
            } else {
                engine.connect(player, to: engine.mainMixerNode, format: format)
            }
            let label = withTimePitch ? "player -> timePitch -> mixer" : "player -> mixer"
            Log.shared.write("engine start (\(label)): \(fmt(milliseconds { try? engine.start() }, 1)) ms")
            defer { engine.stop() }
            var stops: [Double] = []
            for _ in 0..<8 {
                player.scheduleBuffer(tone, at: nil, options: .loops, completionHandler: nil)
                player.play()
                try await pause(1)
                stops.append(milliseconds { player.stop() })
                try await pause(0.5)
            }
            summary("player.stop() while playing, \(label)", stops)
        }
        Log.shared.write("done")
    }
}
