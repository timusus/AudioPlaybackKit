import AVFoundation
import PlaybackDecode
import PlaybackRender

/// The scenarios behind `--check`. Automatic ones play through the speaker under .playAndRecord /
/// .measurement and judge the mic; guided ones run under .playback and wait for the owner.
enum CheckScenarios {
    static let tone = Signals.sine(1000, 0.5)

    /// A 300 -> 3000 Hz sweep every second: no two moments within half a second sound alike, so the mic
    /// can tell which media time it hears.
    static let chirp: Signal = { t, _, _ in
        let tau = t - t.rounded(.down)
        return 0.4 * Float(sin(2 * .pi * (300 * tau + 0.5 * 2700 * tau * tau)))
    }

    static let automatic: [CheckRun.Scenario] = [
        .init(id: "A1", question: "play to heard; .ended against the heard end", guided: false, run: playEnded),
        .init(id: "A2", question: "position against the synchronizer and the heard click", guided: false, run: position),
        .init(id: "A3", question: "dropout at rate 1 -> 2 -> 1", guided: false, run: rateCycle),
        .init(id: "A4", question: "gapless joins: fixture 44.1k stereo -> 48k stereo -> 44.1k mono", guided: false, run: join),
        .init(id: "A5", question: "seek: silence and landing", guided: false, run: seek),
        .init(id: "A6", question: "setNext near the end, and after .ended", guided: false, run: setNext),
        .init(id: "A7", question: "auto-flush re-feed (port override): replayed or skipped audio", guided: false, run: autoFlush),
        .init(id: "A8", question: "auto-flush on rate 1 -> 2 -> 1 -> 0.5", guided: false, run: rateFlush),
        .init(id: "A9", question: "forced route: receiver -> speaker override -> receiver, category playback <-> playAndRecord", guided: false, run: forcedRoute),
        .init(id: "A10", question: "interruption by a non-mixable session in another app", guided: false, run: interruptedByApp),
    ]

    // Wired headphones are left out: A9 moves the route the same way without a person.
    static let guided: [CheckRun.Scenario] = [
        route("G1", "Connect Bluetooth", "Turn on Bluetooth headphones or a speaker and let it connect, or pick it with the button.",
              ports: [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP], arriving: true, picker: true),
        route("G2", "Disconnect Bluetooth", "Turn the Bluetooth device off.", ports: [.bluetoothA2DP, .bluetoothLE, .bluetoothHFP], arriving: false, picker: false),
        route("G3", "Pick AirPlay", "Tap the button and choose an AirPlay 2 speaker, or the Mac with AirPlay Receiver on (System Settings > General > AirDrop & Handoff).",
              ports: [.airPlay], arriving: true, picker: true),
        route("G4", "Back to the iPhone", "Tap the button and choose iPhone.", ports: [.airPlay], arriving: false, picker: true),
        interruption("G5", "Take a call", "Call this iPhone from another phone and answer. Hang up after about 5 s."),
        interruption("G6", "Ask Siri", "Hold the side button and ask Siri the time."),
        .init(id: "G7", question: "Reset media services (#100)", guided: true, run: mediaReset),
    ]

    // MARK: Automatic

    @Sendable static func playEnded() async throws -> [String: Any] {
        try Session.configureMeasurement()
        let ear = try await Ear.start()
        defer { ear.stop() }
        let probe = try CheckProbe()
        probe.transport.setCurrent(item: "A", source: ToneSource(rate: 48000, channels: 2, seconds: 4))
        let playHost = hostNow()
        probe.transport.play()
        let ended = try await probe.until(10) { $0.status == .ended }
        try await pause(0.5)
        let playing = probe.events("status").first { $0.detail == "playing" }?.host
        let endedHost = probe.events("status").first { $0.detail == "ended" }?.host
        guard let loud = ear.tone(from: playHost + 1.5, to: playHost + 3)?.reference,
              let span = ear.tone(from: playHost - 0.2, to: hostNow())?.span(loud: loud) else { throw CheckError("tone not found in the mic") }
        let (on, off) = (span.on - ear.inputLatency, span.off - ear.inputLatency)
        let heard = off - on
        let endedLag = endedHost.map { ($0 - off) * 1000 }
        let metrics: [String: Any] = [
            "playToPlayingEventMs": playing.map { round3(($0 - playHost) * 1000) } ?? NSNull(),
            "playToHeardMs": round3((on - playHost) * 1000), "heardSeconds": round3(heard),
            "endedMinusHeardEndMs": endedLag.map(round3) ?? NSNull(), "lastPositionS": probe.positions.last.map { round3($0.seconds) } ?? NSNull(),
            "outputLatencyMs": round3(Session.shared.outputLatency * 1000), "snrDb": round3(db(loud / max(ear.noise, 1e-9))),
        ]
        let pass = ended && abs(heard - 4) < 0.05 && (endedLag.map { $0 > -20 && $0 < 150 } ?? false)
        return result(pass ? "pass" : "fail",
                      "heard \(fmt(heard)) s of 4; .ended \(endedLag.map { fmt($0, 1) } ?? "never") ms after the heard end; play -> heard \(fmt((on - playHost) * 1000, 0)) ms",
                      metrics)
    }

    @Sendable static func position() async throws -> [String: Any] {
        try Session.configureMeasurement()
        let ear = try await Ear.start()
        defer { ear.stop() }
        let probe = try CheckProbe()
        probe.transport.setCurrent(item: "P", source: ToneSource(rate: 44100, channels: 2, seconds: 13, Signals.click))
        probe.transport.play()
        try await probe.until(20) { ($0.positions.last?.seconds ?? 0) >= 12.6 }
        // The first item starts at output time 0, so a position and the clock differ only by the latency.
        let clockDeltas = probe.positions.filter { $0.seconds > 0.5 }.map { ($0.clock - $0.latency - $0.seconds) * 1000 }
        var heard: [Double] = []
        for k in 2...12 {
            guard let expected = probe.host(item: "P", at: Double(k)), let onset = ear.onset(near: expected) else { continue }
            heard.append((onset - ear.inputLatency - expected) * 1000)
        }
        let latency = Session.shared.outputLatency * 1000
        // The onset finder sometimes locks onto an echo or the wrong edge 20-150 ms early; drop those by
        // median absolute deviation before judging.
        let centre = median(heard)
        let deviation = median(heard.map { abs($0 - centre) })
        let inliers = heard.filter { abs($0 - centre) <= 3 * max(deviation, 1) }
        let metrics: [String: Any] = [
            "heardMinusPositionMs": heard.map(round3), "heardMinusPositionMedianMs": round3(median(heard)),
            "heardMinusPositionInlierMedianMs": round3(median(inliers)), "inliers": inliers.count,
            "positionVsClockMinusLatencyMs": ["median": round3(median(clockDeltas)), "min": round3(clockDeltas.min() ?? .nan), "max": round3(clockDeltas.max() ?? .nan)],
            "outputLatencyMs": round3(latency), "inputLatencyMs": round3(ear.inputLatency * 1000),
        ]
        guard inliers.count >= 5 else { return result("inconclusive", "only \(inliers.count) of \(heard.count) clicks agree", metrics) }
        let spread = (inliers.max()! - inliers.min()!)
        return result(abs(median(inliers)) < 5 ? "pass" : "fail",
                      "click heard \(fmt(median(inliers), 1)) ms after the position said (spread \(fmt(spread, 1)) ms, \(inliers.count) of \(heard.count) clicks); outputLatency \(fmt(latency, 1)) ms; position = clock - latency within \(fmt(clockDeltas.map(abs).max() ?? .nan, 1)) ms",
                      metrics)
    }

    @Sendable static func rateCycle() async throws -> [String: Any] {
        try Session.configureMeasurement()
        let ear = try await Ear.start()
        defer { ear.stop() }
        let probe = try CheckProbe()
        probe.transport.setCurrent(item: "R", source: ToneSource(rate: 48000, channels: 2, seconds: 20))
        probe.transport.play()
        try await probe.until(5) { $0.status == .playing }
        let start = hostNow()
        try await pause(3)
        let up = hostNow()
        probe.transport.setRate(2)
        try await pause(4)
        let down = hostNow()
        probe.transport.setRate(1)
        try await pause(3)
        let end = hostNow()
        let report = ear.report(from: start + 0.5, to: end - 0.2, marks: [up, down])
        let dropouts = ear.dropoutMs(after: [up, down])
        let slope = probe.slope(from: up + 0.6, to: down - 0.1)
        let metrics: [String: Any] = ["glitch": report, "dropoutMs": dropouts.map(round3), "positionRateAt2x": round3(slope),
                                      "positionJumpMs": round3(probe.maxJump(from: start, to: end) * 1000)]
        return result("measured",
                      "dropout \(fmt(dropouts[0], 0)) ms to 2x, \(fmt(dropouts[1], 0)) ms back (ADR: 97 / 140 ms); position runs at \(fmt(slope, 2))x; largest position jump \(fmt(probe.maxJump(from: start, to: end) * 1000, 0)) ms",
                      metrics)
    }

    @Sendable static func join() async throws -> [String: Any] {
        guard let url = Bundle.main.url(forResource: "tone", withExtension: "mp3") else { throw CheckError("tone.mp3 missing from the bundle") }
        try Session.configureMeasurement()
        let ear = try await Ear.start()
        defer { ear.stop() }
        let probe = try CheckProbe()
        // The last 3 s of the 20 s fixture, so the first join comes 3 s in.
        probe.transport.setCurrent(item: "F", source: FFmpegItemSource(reader: try FileByteReader(url: url)), startFrame: 17 * 44100)
        probe.transport.setNext(item: "B", source: ToneSource(rate: 48000, channels: 2, seconds: 3))
        let playHost = hostNow()
        probe.transport.play()
        // Before decode reaches B a second setNext would replace it, so C waits for the crossing.
        try await probe.until(10) { !$0.events("crossed").filter { $0.detail == "B" }.isEmpty }
        probe.transport.setNext(item: "C", source: ToneSource(rate: 44100, channels: 1, seconds: 3))
        let ended = try await probe.until(10) { $0.status == .ended }
        try await pause(0.3)
        let joinB = probe.host(item: "B", at: 0), joinC = probe.host(item: "C", at: 0)
        let crossed = { (item: String, join: Double?) -> Double? in
            guard let join, let event = probe.events("crossed").first(where: { $0.detail == item }) else { return nil }
            return round3((event.host - join) * 1000)
        }
        let fixtureJoinDips = joinB.map { ear.envelopeDipsMs(around: $0) } ?? []
        let toneReport = joinC.map { ear.report(from: $0 - 2, to: $0 + 2, marks: [$0]) } ?? [:]
        let toneJoinDips = joinC.map { ear.dropoutMs(after: [$0 - 0.1], window: 0.3) } ?? []
        let metrics: [String: Any] = [
            "ended": ended, "crossedAfterHeardJoinMs": ["B": crossed("B", joinB) as Any? ?? NSNull(), "C": crossed("C", joinC) as Any? ?? NSNull()],
            "fixtureToTone48kDipsMs": fixtureJoinDips.map(round3), "tone48kToTone44kMonoDipMs": toneJoinDips.map(round3), "toneJoinGlitch": toneReport,
            "heardJoinsAfterPlayS": [joinB.map { round3($0 - playHost) } as Any? ?? NSNull(), joinC.map { round3($0 - playHost) } as Any? ?? NSNull()],
            "failed": probe.events("failed").map(\.detail),
        ]
        guard ended, joinB != nil, joinC != nil else { return result("fail", "ended \(ended), joins heard B \(joinB != nil) C \(joinC != nil)", metrics) }
        return result("measured",
                      "fixture 44.1k -> 48k dips \(fixtureJoinDips.map { fmt($0, 0) }) ms; 48k stereo -> 44.1k mono dip \(fmt(toneJoinDips.first ?? 0, 0)) ms (ADR: 8-11 ms); crossed \(crossed("B", joinB).map { fmt($0, 0) } ?? "?") / \(crossed("C", joinC).map { fmt($0, 0) } ?? "?") ms after the heard joins",
                      metrics)
    }

    @Sendable static func seek() async throws -> [String: Any] {
        try Session.configureMeasurement()
        let ear = try await Ear.start()
        defer { ear.stop() }
        let probe = try CheckProbe()
        probe.transport.setCurrent(item: "S", source: ToneSource(rate: 48000, channels: 2, seconds: 20))
        probe.transport.play()
        try await probe.until(5) { $0.status == .playing }
        try await pause(3)
        let call = hostNow()
        probe.transport.seek(item: "S", toFrame: 12 * 48000)
        try await pause(3)
        let landed = probe.positions.first { $0.host > call }?.seconds
        let gap = ear.tone(from: call - 0.1, to: call + 2)?.dips().first
        let soundBack = gap.map { $0.host + $0.ms / 1000 - ear.inputLatency }
        // Two seconds after the sound came back the position should read 14 s.
        let drift = soundBack.flatMap { back in probe.positions.first { $0.host > back + 2 }.map { ($0.seconds - 12 - ($0.host - back)) * 1000 } }
        let metrics: [String: Any] = [
            "firstPositionAfterSeekS": landed.map(round3) ?? NSNull(), "silenceMs": gap.map { round3($0.ms) } ?? NSNull(),
            "seekToSoundMs": soundBack.map { round3(($0 - call) * 1000) } ?? NSNull(), "positionMinusHeardAfter2sMs": drift.map(round3) ?? NSNull(),
        ]
        let pass = landed == 12 && soundBack.map { $0 - call < 1 } ?? false
        return result(pass ? "pass" : "fail",
                      "landed at \(landed.map { fmt($0) } ?? "?") s of 12; sound back \(soundBack.map { fmt(($0 - call) * 1000, 0) } ?? "?") ms after the call (silence \(gap.map { fmt($0.ms, 0) } ?? "?") ms); position vs heard 2 s on \(drift.map { fmt($0, 1) } ?? "?") ms",
                      metrics)
    }

    @Sendable static func setNext() async throws -> [String: Any] {
        try Session.configureMeasurement()
        let ear = try await Ear.start()
        defer { ear.stop() }
        let probe = try CheckProbe()
        probe.transport.setCurrent(item: "1", source: ToneSource(rate: 48000, channels: 2, seconds: 4))
        probe.transport.play()
        try await probe.until(10) { ($0.positions.last?.seconds ?? 0) >= 3.5 }
        probe.transport.setNext(item: "2", source: ToneSource(rate: 48000, channels: 2, seconds: 3))
        try await probe.until(10) { $0.status == .ended }
        let firstEnd = hostNow()
        try await pause(1)
        let call = hostNow()
        probe.transport.setNext(item: "3", source: ToneSource(rate: 48000, channels: 2, seconds: 1.5))
        try await probe.until(10) { $0.events("status").filter { $0.detail == "ended" }.count >= 2 }
        try await pause(0.3)
        let join = probe.host(item: "2", at: 0)
        let joinDip = join.map { ear.dropoutMs(after: [$0 - 0.1], window: 0.3)[0] }
        let restart = probe.host(item: "3", at: 0)
        let crossed = probe.events("crossed").map(\.detail)
        let statusesAfterEnd = probe.events("status").filter { $0.host > firstEnd }.map(\.detail)
        let ends = probe.events("status").filter { $0.detail == "ended" }.count
        let metrics: [String: Any] = [
            "joinDipMs": joinDip.map(round3) ?? NSNull(), "crossed": crossed, "statusesAfterFirstEnd": statusesAfterEnd, "endedCount": ends,
            "setNextAfterEndedToHeardMs": restart.map { round3(($0 - call) * 1000) } ?? NSNull(),
        ]
        let pass = joinDip == 0 && crossed == ["1", "2", "3"] && ends == 2
        return result(pass ? "pass" : "fail",
                      "join dip \(joinDip.map { fmt($0, 0) } ?? "?") ms; crossed \(crossed); .ended \(ends)x; setNext after .ended heard \(restart.map { fmt(($0 - call) * 1000, 0) } ?? "never") ms later",
                      metrics)
    }

    @Sendable static func autoFlush() async throws -> [String: Any] {
        try Session.configureMeasurement()
        let ear = try await Ear.start()
        defer { ear.stop() }
        let probe = try CheckProbe()
        probe.transport.setCurrent(item: "C", source: ToneSource(rate: 48000, channels: 1, seconds: 30, chirp))
        probe.transport.play()
        try await probe.until(5) { $0.status == .playing }
        try await pause(3)
        // With .defaultToSpeaker the route stays on the speaker, yet each override auto-flushes (spike Q3).
        try Session.shared.overrideOutputAudioPort(.speaker)
        try await pause(3)
        try Session.shared.overrideOutputAudioPort(.none)
        try await pause(3)
        let flushes = probe.flushes.map { flush in
            flushReport(probe, flush).merging(ear.replay(probe, around: flush.host)) { a, _ in a }
        }
        guard !flushes.isEmpty else { return result("inconclusive", "no auto-flush on the port overrides", ["flushes": []]) }
        let summary = flushes.map { f in
            "re-feed \(f["refeedMinusFlushTimeMs"].map { "\($0)" } ?? "?") ms vs flush time, \(f["refeedMinusHeardMs"].map { "\($0)" } ?? "?") ms vs heard; mic: replayed \(f["replayMs"].map { "\($0)" } ?? "?") ms, silence \(f["silenceMs"].map { "\($0)" } ?? "?") ms"
        }
        return result("measured", summary.joined(separator: "; "), ["flushes": flushes, "outputLatencyMs": round3(Session.shared.outputLatency * 1000)])
    }

    // MARK: Guided

    static func route(_ id: String, _ title: String, _ body: String, ports: Set<AVAudioSession.Port>, arriving: Bool, picker: Bool) -> CheckRun.Scenario {
        .init(id: id, question: title, guided: true) {
            try await guidedPlayback(id) { probe in
                let answer = await CheckUI.shared.ask(title, body + "\n\nA tone is playing.", buttons: ["Skip (no device)"], routePicker: picker, cap: 600) { note in
                    guard note.name == AVAudioSession.routeChangeNotification else { return nil }
                    let previous = Set((note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)?.outputs.map(\.portType) ?? [])
                    let current = Set(AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType))
                    let (had, has) = (!previous.isDisjoint(with: ports), !current.isDisjoint(with: ports))
                    return (arriving ? has && !had : had && !has) ? Session.outputs : nil
                }
                return answer
            }
        }
    }

    static func interruption(_ id: String, _ title: String, _ body: String) -> CheckRun.Scenario {
        .init(id: id, question: title, guided: true) {
            try await guidedPlayback(id) { probe in
                let began = await CheckUI.shared.ask(title, body + "\n\nA tone is playing. Tap Done if nothing paused it.", buttons: ["Done", "Skip"], cap: 600) { note in
                    guard note.name == AVAudioSession.interruptionNotification,
                          note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue else { return nil }
                    return "interruption began"
                }
                guard began.hasPrefix("fired") else { return began == "Done" ? "fired: no interruption" : began }
                // What an app does: pause on began, reactivate and play on ended.
                probe.transport.pause()
                let ended = await CheckUI.shared.ask("Finish it", "Hang up or dismiss Siri. The tone comes back by itself.", buttons: ["It's over"], cap: 300) { note in
                    guard note.name == AVAudioSession.interruptionNotification,
                          note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.ended.rawValue else { return nil }
                    let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                    return "ended shouldResume=\(options.contains(.shouldResume))"
                }
                Log.shared.write("interruption end: \(ended)")
                try? Session.shared.setActive(true)
                probe.transport.play()
                return "fired: began, then \(ended)"
            }
        }
    }

    @Sendable static func mediaReset() async throws -> [String: Any] {
        try await guidedPlayback("G7") { probe in
            let answer = await CheckUI.shared.ask("Reset media services", "Open Settings > Developer > Reset Media Services, then come back to this app.\n\nA tone is playing.",
                                                  buttons: ["Skip"], cap: 600) { note in
                note.name == AVAudioSession.mediaServicesWereResetNotification ? "media services reset" : nil
            }
            guard answer.hasPrefix("fired") else { return answer }
            // Apple's advice after a reset: set the session up again; the transport is then asked to play on.
            try? Session.configure(longForm: false)
            probe.transport.play()
            return answer
        }
    }

    /// A 60 s tone under .playback; `trigger` waits for the owner and returns "fired: ..." or why not.
    /// Then 10 s of playing on, a seek to 2 s before the end to see `.ended`, and one question.
    static func guidedPlayback(_ id: String, _ trigger: (CheckProbe) async throws -> String) async throws -> [String: Any] {
        try Session.configure(longForm: false)
        let probe = try CheckProbe()
        let source = ToneSource(rate: 48000, channels: 2, seconds: 60)
        probe.transport.setCurrent(item: "G", source: source)
        probe.transport.play()
        try await probe.until(5) { $0.status == .playing }
        let before: [String: Any] = ["outputs": Session.outputs, "outputLatencyMs": round3(Session.shared.outputLatency * 1000), "hwRate": Session.shared.sampleRate]
        let start = hostNow()
        let answer = try await trigger(probe)
        guard answer.hasPrefix("fired") else { return ["status": "skipped", "verdict": answer] }
        let fired = hostNow()
        await CheckUI.shared.show(id, "Playing on for 10 s; nothing to do.")
        try await pause(10)
        let after: [String: Any] = ["outputs": Session.outputs, "outputLatencyMs": round3(Session.shared.outputLatency * 1000), "hwRate": Session.shared.sampleRate]
        let flushes = probe.flushes.filter { $0.host > start }.map { flushReport(probe, $0) }
        let statuses = probe.events.filter { $0.host > start && $0.kind != "crossed" }.map { "\(fmt($0.host - fired, 2))s \($0.kind) \($0.detail)" }
        let rate = probe.slope(from: fired + 3, to: hostNow())
        let stall = probe.maxStall(from: fired - 1, to: hostNow())

        let seekHost = hostNow()
        await CheckUI.shared.show(id, "Checking that .ended still fires (about 2 s).")
        probe.transport.seek(item: "G", toFrame: source.frames - 2 * 48000)
        let ended = try await probe.until(15) { $0.status == .ended }
        let endedAfter = probe.events("status").last { $0.detail == "ended" }.map { $0.host - seekHost }
        let glitch = await CheckUI.shared.ask("Did you hear a glitch?", "Around the change: a gap, a click or a repeated bit of tone?",
                                              buttons: ["No glitch", "Gap or click", "Repeat"], cap: 45)
        let metrics: [String: Any] = [
            "trigger": answer, "triggerAfterS": round3(fired - start), "before": before, "after": after, "flushes": flushes, "events": statuses,
            "positionRateLast7s": round3(rate), "maxPositionStallMs": round3(stall * 1000), "positionJumpMs": round3(probe.maxJump(from: fired - 1, to: seekHost) * 1000),
            "endedFired": ended, "endedAfterSeekS": endedAfter.map(round3) ?? NSNull(), "heardGlitch": glitch,
        ]
        let refeed = flushes.map { "re-feed \($0["refeedMinusHeardMs"].map { "\($0)" } ?? "?") ms vs heard" }
        let ok = ended && abs(rate - 1) < 0.05 && probe.events("failed").isEmpty
        return result(ok ? "pass" : "fail",
                      "\(answer); \(flushes.count) auto-flush(es) \(refeed); latency \(before["outputLatencyMs"] ?? "?") -> \(after["outputLatencyMs"] ?? "?") ms; position rate \(fmt(rate, 2)), stall \(fmt(stall * 1000, 0)) ms; .ended \(ended ? "after \(fmt(endedAfter ?? 0, 2)) s" : "never"); owner: \(glitch)",
                      metrics)
    }

    // MARK: Analysis

    static func result(_ status: String, _ verdict: String, _ metrics: [String: Any]) -> [String: Any] {
        metrics.merging(["status": status, "verdict": verdict]) { _, new in new }
    }

    /// Where the transport re-fed from, against the renderer's flush time and the heard time at the
    /// notification, both mapped to media through the positions just before.
    static func flushReport(_ probe: CheckProbe, _ flush: CheckProbe.Flush) -> [String: Any] {
        let before = probe.positions.filter { $0.host < flush.host && $0.host > flush.host - 1 && $0.seconds > 0 }
        let offset = median(before.map { $0.clock - $0.latency - $0.seconds })
        let refeed = probe.positions.filter { $0.host > flush.host && $0.host < flush.host + 0.5 }.map(\.seconds).min()
        let heard = flush.clock - flush.latency - offset
        let flushMedia = flush.flushTime.map { $0 - offset }
        var report: [String: Any] = [
            "flushTime": flush.flushTime.map(round3) ?? NSNull(), "clockAtNotification": round3(flush.clock), "outputLatencyMs": round3(flush.latency * 1000),
            "flushTimeMinusClockMs": flush.flushTime.map { round3(($0 - flush.clock) * 1000) } ?? NSNull(),
        ]
        guard !before.isEmpty, let refeed else { return report.merging(["note": "no positions around the flush"]) { a, _ in a } }
        report["refeedS"] = round3(refeed)
        report["refeedMinusHeardMs"] = round3((refeed - heard) * 1000)
        report["refeedMinusFlushTimeMs"] = flushMedia.map { round3((refeed - $0) * 1000) } ?? NSNull()
        return report
    }
}

extension CheckProbe {
    /// Media seconds per host second over positions in the window.
    func slope(from: Double, to: Double) -> Double {
        let window = positions.filter { $0.host >= from && $0.host <= to }
        guard let a = window.first, let b = window.last, b.host > a.host else { return .nan }
        return (b.seconds - a.seconds) / (b.host - a.host)
    }

    /// The longest host gap between position events in the window: they come every pump while the
    /// heard position moves.
    func maxStall(from: Double, to: Double) -> Double {
        let hosts = positions.filter { $0.host >= from && $0.host <= to }.map(\.host)
        return zip(hosts, hosts.dropFirst()).map { $1 - $0 }.max() ?? .nan
    }

    /// The largest step between consecutive positions beyond what the elapsed time explains at
    /// whatever rate held: a skip (positive) or a repeat (negative), in seconds.
    func maxJump(from: Double, to: Double) -> Double {
        let window = positions.filter { $0.host >= from && $0.host <= to }
        let steps = zip(window, window.dropFirst()).map { a, b -> Double in
            let elapsed = b.host - a.host
            let moved = b.seconds - a.seconds
            return moved < 0 ? moved : max(0, moved - 2 * elapsed)
        }
        return steps.max { abs($0) < abs($1) } ?? 0
    }
}

/// The mic for one automatic scenario, with the room noise measured before the tone starts.
final class Ear: @unchecked Sendable {
    let mic = MicRecorder()
    private(set) var noise = 0.0
    let inputLatency = Session.shared.inputLatency

    static func start() async throws -> Ear {
        let ear = Ear()
        try ear.mic.start()
        let quiet = hostNow()
        try await pause(0.6)
        ear.noise = ear.tone(from: quiet + 0.1, to: quiet + 0.5)?.reference ?? 0
        return ear
    }

    func stop() {
        mic.stop()
        mic.save(as: "mic-\(AutoRun.current).wav")
    }

    func tone(hz: Double = 1000, from: Double, to: Double) -> Tone? {
        mic.chunk(from: from, to: to).map { Tone($0, hz: hz, from: from, to: to) }
    }

    /// The spike's glitch report for a steady 1 kHz tone, in host time.
    func report(from: Double, to: Double, marks: [Double]) -> [String: Any] {
        guard let tone = tone(from: from, to: to) else { return ["error": "no recording"] }
        let dips = tone.dips(), jumps = tone.phaseJumps()
        let near = { (h: Double) in marks.contains { abs($0 - h) < 0.35 } }
        return [
            "levelDb": round3(db(tone.reference)), "snrDb": round3(db(tone.reference / max(noise, 1e-9))),
            "dips": dips.map { ["at": round3($0.host - from), "ms": round3($0.ms)] }, "phaseJumps": jumps.count,
            "dipsNearMarks": dips.filter { near($0.host) }.count, "phaseJumpsNearMarks": jumps.filter(near).count,
        ]
    }

    /// Total 1 kHz dip after each mark within `window` seconds; 0 when none.
    func dropoutMs(after marks: [Double], window: Double = 0.7) -> [Double] {
        marks.map { mark in
            tone(from: mark - 1, to: mark + window + 1)?.dips().filter { $0.host >= mark && $0.host < mark + window }.reduce(0) { $0 + $1.ms } ?? .nan
        }
    }

    /// Broadband dips of 5 ms or more, over 6 dB under the quieter side, within 0.35 s of `mark`: for a
    /// join between unlike signals, where a single-frequency demodulator does not apply.
    func envelopeDipsMs(around mark: Double) -> [Double] {
        let blocks = rms(from: mark - 0.8, to: mark + 0.8)
        guard blocks.count > 1500 else { return [.nan] }
        let level = min(median(Array(blocks[100..<750])), median(Array(blocks[850..<1500])))
        var runs: [Double] = [], start: Int?
        for (i, value) in (blocks[450..<1150] + [Double.infinity]).enumerated() {
            if value < level / 2 { start = start ?? i; continue }
            if let s = start, i - s >= 5 { runs.append(Double(i - s)) }
            start = nil
        }
        return runs
    }

    /// The heard media time at host `from` for a known signal, by sliding it over the recording within
    /// `span` of `prior`, then to the nearest sample. Nil when the match is weak.
    func media(at from: Double, prior: Double, span: Double, _ signal: Signal) -> (media: Double, correlation: Double)? {
        let length = 0.1
        guard let chunk = mic.chunk(from: from, to: from + length) else { return nil }
        let first = Int(((from - chunk.hostStart) * chunk.rate).rounded()), count = Int(length * chunk.rate)
        guard first >= 0, first + count <= chunk.samples.count else { return nil }
        let recorded = chunk.samples[first..<(first + count)].map(Double.init)
        let recordedEnergy = recorded.reduce(0) { $0 + $1 * $1 }
        func score(_ media: Double) -> Double {
            var dot = 0.0, energy = 0.0
            for i in 0..<count {
                let s = Double(signal(media + Double(i) / chunk.rate, 0, 0))
                dot += recorded[i] * s
                energy += s * s
            }
            return abs(dot) / max(sqrt(energy * recordedEnergy), 1e-12)
        }
        var best = (media: prior, correlation: 0.0)
        for step in [0.00025, 1 / chunk.rate] {
            let (centre, width) = step == 0.00025 ? (prior, span) : (best.media, 0.0003)
            var media = centre - width
            while media <= centre + width {
                let s = score(media)
                if s > best.correlation { best = (media, s) }
                media += step
            }
        }
        return best.correlation > 0.3 ? best : nil
    }

    /// Around an auto-flush of the chirp: how long the speaker went quiet, and how much media the
    /// re-feed repeated (positive) or skipped (negative) on top of that silence.
    func replay(_ probe: CheckProbe, around host: Double) -> [String: Any] {
        let origin = host - 0.6
        let blocks = rms(from: origin, to: host + 1.5)
        guard blocks.count > 1000 else { return ["micNote": "no recording"] }
        let level = median(Array(blocks[0..<300]))
        var silence: (Double, Double)?
        if let low = (300..<(blocks.count - 5)).first(where: { i in blocks[i..<(i + 3)].allSatisfy { $0 < level / 4 } }),
           let back = (low..<(blocks.count - 5)).first(where: { i in blocks[i..<(i + 5)].allSatisfy { $0 > level / 2 } }) {
            silence = (origin + Double(low) / 1000, origin + Double(back) / 1000)
        }
        let before = (silence?.0 ?? host - 0.3) - 0.13
        let after = (silence?.1 ?? host + 1) + 0.03
        guard let p = probe.positions.last(where: { $0.host <= before }),
              let q = probe.positions.first(where: { $0.host >= after + 0.3 }),
              let m1 = media(at: before - inputLatency, prior: p.seconds + (before - p.host), span: 0.08, CheckScenarios.chirp),
              let m2 = media(at: after - inputLatency, prior: q.seconds - (q.host - after), span: 0.15, CheckScenarios.chirp)
        else { return ["micNote": "chirp not matched in the mic", "silenceMs": silence.map { round3(($0.1 - $0.0) * 1000) } ?? NSNull()] }
        let lost = (m1.media - before) - (m2.media - after)
        let quiet = silence.map { $0.1 - $0.0 } ?? 0
        return [
            "silenceMs": round3(quiet * 1000), "mediaLostMs": round3(lost * 1000), "replayMs": round3((lost - quiet) * 1000),
            "correlation": [round3(m1.correlation), round3(m2.correlation)],
        ]
    }

    /// RMS in 1 ms blocks.
    private func rms(from: Double, to: Double) -> [Double] {
        guard let chunk = mic.chunk(from: from, to: to) else { return [] }
        let n = Int(chunk.rate / 1000)
        var i = max(0, Int(((from - chunk.hostStart) * chunk.rate).rounded()))
        let last = min(chunk.samples.count, Int(((to - chunk.hostStart) * chunk.rate).rounded()))
        var blocks: [Double] = []
        while i + n <= last {
            blocks.append(sqrt(chunk.samples[i..<(i + n)].reduce(0) { $0 + Double($1) * Double($1) } / Double(n)))
            i += n
        }
        return blocks
    }

    /// The spike's click onset: the first sample edge over 30% of the peak, near `expected`.
    func onset(near expected: Double) -> Double? {
        guard let chunk = mic.chunk(from: expected - 0.15, to: expected + 0.35) else { return nil }
        let from = max(1, Int(((expected - 0.15 - chunk.hostStart) * chunk.rate).rounded()))
        let to = min(chunk.samples.count, Int(((expected + 0.35 - chunk.hostStart) * chunk.rate).rounded()))
        guard to > from + 10 else { return nil }
        let edge = (from..<to).map { abs(chunk.samples[$0] - chunk.samples[$0 - 1]) }
        let floor = median(edge.map(Double.init))
        let peak = Double(edge.max() ?? 0)
        guard peak > 10 * floor, let onset = edge.firstIndex(where: { Double($0) > 0.3 * peak }) else { return nil }
        return chunk.hostStart + Double(from + onset) / chunk.rate
    }
}
