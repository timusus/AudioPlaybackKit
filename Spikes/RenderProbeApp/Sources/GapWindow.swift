import Foundation

/// Session set-up for a guided check: the mic needs a record category, which .longFormAudio refuses.
enum GuidedPolicy {
    case plain, longForm, mic
}

extension CheckScenarios {
    struct GapWindow {
        let metrics: [String: Any]
        let summary: String
    }

    /// Heard dips and position stalls from playback start to `end`, each placed against the first picker
    /// opening in the window and against the route firing. Dips stop at `fired`: the speaker goes quiet when
    /// the route moves away, which is not a gap.
    static func gapWindow(_ probe: CheckProbe, ear: Ear?, playHost: Double, fired: Double, end: Double) -> GapWindow {
        let opens = PickerMarks.shared.opens.filter { $0 > playHost }
        let closes = PickerMarks.shared.closes.filter { $0 > playHost }
        let opened = opens.first
        let place = { (host: Double) -> [String: Any] in
            ["sincePlayS": round3(host - playHost), "sincePickerOpenS": opened.map { round3(host - $0) } ?? NSNull(), "sinceFiredS": round3(host - fired)]
        }
        let hosts = probe.positions.filter { $0.host >= playHost && $0.host <= end }.map(\.host)
        let stalls = zip(hosts, hosts.dropFirst()).filter { $1 - $0 > 0.25 }.map { place($0).merging(["ms": round3(($1 - $0) * 1000)]) { a, _ in a } }
        var metrics: [String: Any] = [
            "pickerOpensSincePlayS": opens.map { round3($0 - playHost) }, "pickerClosesSincePlayS": closes.map { round3($0 - playHost) },
            "firedSincePlayS": round3(fired - playHost), "stallsOver250ms": stalls,
        ]
        var summary = "picker opened \(opened.map { fmt($0 - playHost, 1) } ?? "never") s after play, route fired \(fmt(fired - playHost, 1)) s; \(stalls.count) position stall(s) over 250 ms"
        if let ear {
            guard let tone = ear.tone(from: playHost + 0.5, to: fired) else {
                metrics["dips"] = "no recording"
                return GapWindow(metrics: metrics, summary: summary + "; mic: no recording")
            }
            let dips = tone.dips().map { place($0.host).merging(["ms": round3($0.ms)]) { a, _ in a } }
            metrics["dips"] = dips
            metrics["micLevelDb"] = round3(db(tone.reference))
            metrics["micSnrDb"] = round3(db(tone.reference / max(ear.noise, 1e-9)))
            let first = tone.dips().first.map { "first at \(fmt($0.host - (opened ?? playHost), 2)) s after \(opened == nil ? "play" : "picker open"), \(fmt($0.ms, 0)) ms" } ?? "none"
            summary += "; heard dips before the route fired: \(dips.count) (\(first))"
        }
        return GapWindow(metrics: metrics, summary: summary)
    }
}
