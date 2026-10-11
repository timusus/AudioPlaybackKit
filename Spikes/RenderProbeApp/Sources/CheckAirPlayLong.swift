import AVFoundation
import PlaybackRender

/// G8: the same 30 s steady tone over one AirPlay route, first through `Transport`, then through `AVPlayer`
/// as a control. A recording on the receiving Mac, aligned by the marks in the result, says which half breaks up.
extension CheckScenarios {
    static let longToneSeconds = 30.0

    static let longTone = CheckRun.Scenario(id: "G8", question: "Long AirPlay tone: Transport, then AVPlayer", guided: true, run: longAirPlayTone)

    static var onAirPlay: Bool {
        Session.shared.currentRoute.outputs.contains { $0.portType == .airPlay }
    }

    @Sendable static func longAirPlayTone() async throws -> [String: Any] {
        try Session.configure(longForm: false)
        if !onAirPlay {
            let picked = await CheckUI.shared.ask("Pick the Mac", "Open the picker and pick the Mac.", buttons: ["Skip (no device)"], routePicker: true, cap: 60) { note in
                note.name == AVAudioSession.routeChangeNotification && onAirPlay ? Session.outputs : nil
            }
            guard picked.hasPrefix("fired") else {
                return result(picked == "timeout" ? "inconclusive" : "skipped", picked == "timeout" ? "route never became AirPlay in 60 s" : picked, [:])
            }
        }
        let route = Session.outputs
        await CheckUI.shared.show("G8", "Letting AirPlay settle (3 s).")
        try await pause(3)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("g8-tone.wav")
        try writeTone(to: file, rate: 48000, seconds: longToneSeconds)

        var marks: [String: String] = [:]
        func mark(_ name: String) {
            let stamp = isoFormatter.string(from: Date())
            marks[name] = stamp
            Log.shared.write("G8 MARK \(name) \(stamp)")
        }

        await CheckUI.shared.show("G8", "Transport tone, 30 s.")
        let probe = try CheckProbe()
        probe.transport.setCurrent(item: "T", source: ToneSource(rate: 48000, channels: 1, seconds: longToneSeconds))
        let transportBegin = hostNow()
        mark("transport-start")
        probe.transport.play()
        let transportEnded = try await probe.until(longToneSeconds + 15) { $0.status == .ended }
        mark("transport-end")
        let transportEnd = hostNow()
        probe.transport.stop()
        let flushes = probe.flushes.filter { $0.host >= transportBegin && $0.host <= transportEnd }.map { flushReport(probe, $0) }
        let stall = probe.maxStall(from: transportBegin + 1, to: transportEnd)
        let failed = probe.events("failed").map(\.detail)

        try await pause(2)
        await CheckUI.shared.show("G8", "AVPlayer tone, 30 s.")
        let item = AVPlayerItem(url: file)
        let player = AVPlayer(playerItem: item)
        let finished = Gate()
        let stalls = StallCount()
        let observers = [
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: nil) { _ in finished.resolve("ended") },
            NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: nil) { _ in stalls.add() },
        ]
        defer { observers.forEach(NotificationCenter.default.removeObserver) }
        mark("avplayer-start")
        player.play()
        Task {
            try? await pause(longToneSeconds + 15)
            finished.resolve("timeout")
        }
        let avplayerEnd = await finished.wait()
        mark("avplayer-end")
        player.pause()

        let back = await CheckUI.shared.ask("Back to the iPhone", "Tap the button and choose iPhone.", buttons: ["Done"], routePicker: true, cap: 120) { note in
            note.name == AVAudioSession.routeChangeNotification && !onAirPlay ? Session.outputs : nil
        }
        Log.shared.write("G8 back to iPhone: \(back)")
        let heard = await CheckUI.shared.ask("Which half was choppy?", "Transport was the first 30 s, AVPlayer the second.",
                                             buttons: ["Transport half choppy", "AVPlayer half choppy", "Both", "Neither"], cap: 300)

        let markText = ["transport-start", "transport-end", "avplayer-start", "avplayer-end"].map { "\($0) \(marks[$0] ?? "?")" }.joined(separator: ", ")
        let metrics: [String: Any] = [
            "route": route, "marksUtc": marks, "transportEnded": transportEnded, "transportFlushes": flushes,
            "transportMaxPositionStallMs": round3(stall * 1000), "transportFailed": failed,
            "avplayerEnd": avplayerEnd, "avplayerStalls": stalls.count, "owner": heard,
        ]
        let ok = transportEnded && failed.isEmpty && avplayerEnd == "ended"
        return result(ok ? "measured" : "fail",
                      "marks (UTC) \(markText); route \(route); Transport: \(flushes.count) auto-flush(es), max position stall \(fmt(stall * 1000, 0)) ms, ended \(transportEnded)\(failed.isEmpty ? "" : ", failed \(failed)"); AVPlayer: \(stalls.count) stall(s), \(avplayerEnd); owner: \(heard)",
                      metrics)
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// The same samples `ToneSource` feeds the transport, so both halves play an identical tone.
    static func writeTone(to url: URL, rate: Double, seconds: Double) throws {
        try? FileManager.default.removeItem(at: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let out = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = Int(seconds * rate)
        var written = 0
        while written < total {
            let count = min(4096, total - written)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count { buffer.floatChannelData![0][i] = tone(Double(written + i) / rate, 0, 0) }
            try out.write(from: buffer)
            written += count
        }
    }

    final class StallCount: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func add() { lock.withLock { value += 1 } }
    }
}
