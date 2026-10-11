import AVFoundation
import PlaybackRender

/// A8-A11: auto-flush and interruption causes a machine can trigger. Each plays the chirp through some
/// steps and reports, per step, the auto-flushes with where the transport re-fed, outputLatency either
/// side, position jumps and clock steps back; then whether `.ended` still fires.
extension CheckScenarios {
    struct Step {
        let name: String
        /// The fastest rate in the step, so a position running ahead at it is not reported as a skip.
        var maxRate = 2.0
        let act: (CheckProbe) async throws -> Void
    }

    static var interruptorFlag: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("interruptor-wanted")
    }

    static var callFlag: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("callkit-wanted")
    }

    @Sendable static func rateFlush() async throws -> [String: Any] {
        try Session.configureMeasurement()
        let ear = try await Ear.start()
        // Time-pitch makes the chirp unmatchable across a rate change, so the mic gives silence only.
        return try await flushRun(ear: ear, replayFromMic: false, [2.0, 1, 0.5, 1, 3].map { rate in
            Step(name: "rate \(fmt(rate, 1))", maxRate: max(rate, 2)) { $0.transport.setRate(rate) }
        })
    }

    @Sendable static func forcedRoute() async throws -> [String: Any] {
        let session = Session.shared
        try? session.setActive(false)
        // Without .defaultToSpeaker .playAndRecord plays on the receiver, so each override really moves the route.
        try session.setCategory(.playAndRecord, mode: .measurement, options: [])
        try session.setActive(true)
        Log.shared.write("session .playAndRecord .measurement no defaultToSpeaker: \(Session.snapshot)")
        let ear = try await Ear.start()
        return try await flushRun(ear: ear, replayFromMic: true, [
            Step(name: "override speaker") { _ in try session.overrideOutputAudioPort(.speaker) },
            Step(name: "override none") { _ in try session.overrideOutputAudioPort(.none) },
            // .playback refuses to replace a category with running input (!pri), so the mic sits this one out.
            Step(name: "category playback") { _ in
                ear.mic.stop()
                try session.setCategory(.playback, mode: .default, options: [])
            },
            Step(name: "category playAndRecord") { _ in
                try session.setCategory(.playAndRecord, mode: .measurement, options: [])
                try ear.mic.start()
            },
        ])
    }

    /// run-devicecheck.sh sees the flag and launches InterruptorApp, whose non-mixable session interrupts
    /// this one for 3 s and then reopens this app. The probe does what an app does: pause, then reactivate and play.
    @Sendable static func interruptedByApp() async throws -> [String: Any] {
        try Session.configure(longForm: false)
        return try await flushRun(ear: nil, replayFromMic: false, signal: hush, [
            Step(name: "InterruptorApp") { probe in
                let began = await interruption(.began, cap: 45) {
                    FileManager.default.createFile(atPath: interruptorFlag.path, contents: nil)
                }
                guard began != "timeout" else { throw CheckError("no interruption in 45 s; only run-devicecheck.sh launches InterruptorApp") }
                probe.transport.pause()
                let ended = await interruption(.ended, cap: 20)
                Log.shared.write("interruption ended: \(ended)")
                try await reactivateSession()
                probe.transport.play()
            },
        ])
    }

    /// Unlike A10 the probe does not pause on `.began` or play on `.ended`: the library owns no interruption
    /// policy, so this records what the transport does by itself. The final play() only lets `.ended` be checked.
    /// run-devicecheck.sh sees the flag and launches InterruptorApp --call, which reports and answers a CallKit
    /// call for 5 s (the app that plays cannot be interrupted by its own call, so the call lives in the other app).
    @Sendable static func interruptedByCall() async throws -> [String: Any] {
        try Session.configure(longForm: false)
        return try await flushRun(ear: nil, replayFromMic: false, signal: hush, [
            Step(name: "CallKit call") { probe in
                let began = await interruption(.began, cap: 45) {
                    FileManager.default.createFile(atPath: callFlag.path, contents: nil)
                }
                guard began != "timeout" else { throw CheckError("no interruption in 45 s; only run-devicecheck.sh launches InterruptorApp --call") }
                try await pause(1)
                probe.note("statusDuringCall", "\(probe.status)")
                probe.note("synchronizerRateDuringCall", round3(Double(probe.synchronizer.rate)))
                let ended = await interruption(.ended, cap: 30)
                probe.note("interruptionEnded", ended)
                try await reactivateSession()
                try await pause(1)
                probe.note("statusAfterCall", "\(probe.status)")
                probe.note("synchronizerRateAfterCall", round3(Double(probe.synchronizer.rate)))
                probe.transport.play()
            },
        ])
    }

    /// The ended note reaches this app in the background while InterruptorApp still holds the foreground,
    /// and activation fails (!int) until it reopens this app.
    static func reactivateSession() async throws {
        var attempts = 1
        while (try? Session.shared.setActive(true)) == nil {
            guard attempts < 40 else { throw CheckError("session not reactivated in 10 s") }
            attempts += 1
            try await pause(0.25)
        }
        Log.shared.write("session reactivated after \(attempts) attempt(s)")
    }

    /// "shouldResume", "fired" or "timeout" for the first interruption of `type` after `trigger`.
    static func interruption(_ type: AVAudioSession.InterruptionType, cap: Double, trigger: () -> Void = {}) async -> String {
        let gate = Gate()
        let observer = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { note in
            guard note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == type.rawValue else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            gate.resolve(options.contains(.shouldResume) ? "shouldResume" : "fired")
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        trigger()
        Task {
            try? await pause(cap)
            gate.resolve("timeout")
        }
        return await gate.wait()
    }

    /// Plays 40 s of `signal`, runs `steps` 3 s apart, then seeks to 2 s before the end to see `.ended`.
    static func flushRun(ear: Ear?, replayFromMic: Bool, signal: @escaping Signal = chirp, _ steps: [Step]) async throws -> [String: Any] {
        defer { ear?.stop() }
        let probe = try CheckProbe()
        let trace = ClockTrace(probe.synchronizer)
        defer { trace.stop() }
        let source = ToneSource(rate: 48000, channels: 1, seconds: 40, signal)
        probe.transport.setCurrent(item: "F", source: source)
        probe.transport.play()
        try await probe.until(5) { $0.status == .playing }
        try await pause(3)
        var done: [(step: Step, begin: Double, latency: Double, outputs: String)] = []
        for step in steps {
            done.append((step, hostNow(), Session.shared.outputLatency, Session.outputs))
            Log.shared.write("STEP \(step.name)")
            try await step.act(probe)
            try await pause(3)
        }
        let seekHost = hostNow()
        probe.transport.seek(item: "F", toFrame: source.frames - 2 * 48000)
        let ended = try await probe.until(15) { $0.status == .ended }
        let endedAfter = probe.events("status").last { $0.detail == "ended" }.map { $0.host - seekHost }

        var reports: [[String: Any]] = [], summaries: [String] = []
        for (i, entry) in done.enumerated() {
            let end = i + 1 < done.count ? done[i + 1].begin : seekHost
            let after = probe.positions.last { $0.host < end }?.latency ?? .nan
            let flushes = probe.flushes.filter { $0.host >= entry.begin && $0.host < end }.map { flush in
                var report = flushReport(probe, flush)
                if let ear {
                    let heard = ear.replay(probe, around: flush.host)
                    report.merge(replayFromMic ? heard : heard.filter { $0.key == "silenceMs" }) { a, _ in a }
                }
                return report
            }
            let jump = probe.maxJump(from: entry.begin - 0.5, to: end, maxRate: entry.step.maxRate) * 1000
            let stepBack = trace.largestStepBack(from: entry.begin - 0.5, to: end) * 1000
            reports.append([
                "step": entry.step.name, "outputsBefore": entry.outputs, "outputsAfter": Session.outputs,
                "outputLatencyMs": [round3(entry.latency * 1000), round3(after * 1000)], "flushes": flushes,
                "positionJumpMs": round3(jump), "clockStepBackMs": round3(stepBack),
            ])
            let described = flushes.map { f in
                "re-feed \(f["refeedMinusHeardMs"].map { "\($0)" } ?? "?") ms vs heard, \(f["refeedMinusFlushTimeMs"].map { "\($0)" } ?? "?") vs flush time"
                    + (f["replayMs"].map { ", mic replay \($0) ms" } ?? "") + (f["silenceMs"].map { ", silence \($0) ms" } ?? "")
            }
            summaries.append("\(entry.step.name): \(flushes.count) flush(es)\(described.isEmpty ? "" : " (\(described.joined(separator: "; ")))"), latency \(fmt(entry.latency * 1000, 1)) -> \(fmt(after * 1000, 1)) ms, jump \(fmt(jump, 0)) ms, clock back \(fmt(stepBack, 1)) ms")
        }
        let failed = probe.events("failed").map(\.detail)
        var metrics: [String: Any] = ["steps": reports, "endedFired": ended, "endedAfterSeekS": endedAfter.map(round3) ?? NSNull(), "failed": failed]
        if !probe.notes.isEmpty { metrics["observed"] = probe.notes }
        return result(ended && failed.isEmpty ? "measured" : "fail",
                      summaries.joined(separator: " / ") + (probe.notes.isEmpty ? "" : "; observed \(probe.notes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" })") + "; .ended \(ended ? "after \(fmt(endedAfter ?? 0, 2)) s" : "never")" + (failed.isEmpty ? "" : "; failed \(failed)"),
                      metrics)
    }
}
