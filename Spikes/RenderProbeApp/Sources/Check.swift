import AVFoundation
import PlaybackRender
import SwiftUI

/// The device check (`--check`): PlaybackRender's public `Transport` through each ADR-0018 device question,
/// automatic scenarios first, then guided ones that wait for the owner. Writes `check.json`, `check.md` and
/// a `check-done` flag to Documents for run-devicecheck.sh to poll and copy back.
enum CheckRun {
    static let enabled = CommandLine.arguments.contains("--check")
    /// Lets an unattended run finish without anyone at the phone.
    static let skipGuided = CommandLine.arguments.contains("--skip-guided")

    struct Scenario {
        let id: String
        let question: String
        let guided: Bool
        let run: @Sendable () async throws -> [String: Any]
    }

    static func run() async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let jsonURL = documents.appendingPathComponent("check.json")
        let markdownURL = documents.appendingPathComponent("check.md")
        let doneURL = documents.appendingPathComponent("check-done")
        for url in [jsonURL, markdownURL, doneURL] { try? FileManager.default.removeItem(at: url) }
        await MainActor.run { UIApplication.shared.isIdleTimerDisabled = true }
        let started = Date()
        Log.shared.write("CHECK start skipGuided=\(skipGuided)")

        let mic = await AutoRun.micPermission()
        let (model, version) = await MainActor.run { (UIDevice.current.model, UIDevice.current.systemVersion) }
        try? await pause(1)
        let originalVolume = Session.shared.outputVolume
        await AutoRun.setVolume(0.75)
        let header: [String: Any] = ["device": model, "ios": version, "started": ISO8601DateFormatter().string(from: started),
                                     "micPermission": mic, "skipGuided": skipGuided]
        var results: [[String: Any]] = []
        for scenario in CheckScenarios.automatic + CheckScenarios.guided {
            AutoRun.current = "check-\(scenario.id)"
            await CheckUI.shared.show(scenario.id, scenario.question)
            if scenario.guided, !results.contains(where: { $0["guided"] as? Bool == true }) {
                // The owner's routes and calls are louder than a test tone at 0.75.
                await AutoRun.setVolume(originalVolume)
            }
            Log.shared.write("=== CHECK \(scenario.id) \(scenario.question) ===")
            var entry: [String: Any] = ["id": scenario.id, "question": scenario.question, "guided": scenario.guided]
            let begin = hostNow()
            if scenario.guided, skipGuided {
                entry["status"] = "skipped"
                entry["verdict"] = "skipped by --skip-guided"
            } else if !scenario.guided, mic != "granted" {
                entry["status"] = "skipped"
                entry["verdict"] = "mic permission \(mic)"
            } else {
                do {
                    // Guided steps wait on a person, so only a hang in code should cut them short.
                    entry.merge(try await withTimeout(scenario.guided ? 900 : 90, scenario.run)) { _, new in new }
                } catch is AutoRun.TimedOut {
                    entry["status"] = "timeout"
                    entry["verdict"] = "no result in time"
                } catch {
                    entry["status"] = "error"
                    entry["verdict"] = "\(error)"
                }
            }
            entry["seconds"] = round3(hostNow() - begin)
            Log.shared.write("CHECK \(scenario.id): \(entry["status"] ?? "?") - \(entry["verdict"] ?? "")")
            results.append(entry)
            write(header, results, complete: false, json: jsonURL, markdown: markdownURL)
        }
        write(header, results, complete: true, json: jsonURL, markdown: markdownURL)
        await AutoRun.setVolume(originalVolume)
        FileManager.default.createFile(atPath: doneURL.path, contents: Data("done\n".utf8))
        Log.shared.write("CHECK done in \(fmt(Date().timeIntervalSince(started), 0)) s")
        await CheckUI.shared.show("Done", "Results are in the app's Documents (check.md, check.json).")
    }

    private static func write(_ header: [String: Any], _ results: [[String: Any]], complete: Bool, json: URL, markdown: URL) {
        let object = header.merging(["complete": complete, "scenarios": results]) { a, _ in a }
        do {
            try JSONSerialization.data(withJSONObject: sanitize(object), options: [.prettyPrinted, .sortedKeys]).write(to: json)
        } catch {
            Log.shared.write("check.json write failed: \(error)")
        }
        var lines = ["# PlaybackRender device check", "",
                     "\(header["device"] ?? "?") iOS \(header["ios"] ?? "?"), started \(header["started"] ?? "?"), mic \(header["micPermission"] ?? "?")"
                         + (complete ? "" : " (incomplete)"), "",
                     "| Scenario | Status | Result |", "|---|---|---|"]
        for result in results {
            let verdict = "\(result["verdict"] ?? "")".replacingOccurrences(of: "|", with: "/")
            lines.append("| \(result["id"] ?? "?") | \(result["status"] ?? "?") | \(verdict) |")
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: markdown, atomically: true, encoding: .utf8)
    }

    /// JSON has no NaN or infinity; those become null.
    private static func sanitize(_ value: Any) -> Any {
        switch value {
        case let d as Double: return d.isFinite ? d : NSNull()
        case let dict as [String: Any]: return dict.mapValues(sanitize)
        case let array as [Any]: return array.map(sanitize)
        default: return value
        }
    }
}

struct CheckError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Generated PCM as a transport item, so every sample heard is known.
final class ToneSource: ItemSource, @unchecked Sendable {
    let format: PCMFormat
    let frames: Int64
    private let signal: Signal
    private let lock = NSLock()
    private var frame: Int64 = 0

    init(rate: Double, channels: Int, seconds: Double, _ signal: @escaping Signal = CheckScenarios.tone) {
        format = PCMFormat(sampleRate: rate, channelCount: channels)
        frames = Int64((seconds * rate).rounded())
        self.signal = signal
    }

    var seconds: Double { Double(frames) / format.sampleRate }

    func begin(epoch: UInt64) {}

    func open() throws -> PCMFormat {
        lock.withLock { frame = 0 }
        return format
    }

    func seek(toFrame frame: Int64) throws -> Int64 {
        let landed = min(frame, frames)
        lock.withLock { self.frame = landed }
        return landed
    }

    func nextChunk() throws -> [Float]? {
        let (start, count) = lock.withLock { () -> (Int64, Int64) in
            let count = min(4096, frames - frame)
            defer { frame += count }
            return (frame, count)
        }
        guard count > 0 else { return nil }
        var samples: [Float] = []
        samples.reserveCapacity(Int(count) * format.channelCount)
        for f in start..<(start + count) {
            let t = Double(f) / format.sampleRate
            for channel in 0..<format.channelCount { samples.append(signal(t, channel, 0)) }
        }
        return samples
    }

    func interrupt(through epoch: UInt64) {}
}

/// A `Transport` with every event stamped in host time, plus the synchronizer clock and auto-flushes
/// that the public API keeps inside. Those two are read by reflection, for measuring only.
final class CheckProbe: @unchecked Sendable {
    struct Event { let host: Double; let kind: String; let detail: String }
    struct Position { let host: Double; let item: String; let seconds: Double; let clock: Double; let latency: Double }
    struct Flush { let host: Double; let flushTime: Double?; let clock: Double; let latency: Double }

    let transport: Transport<String>
    let synchronizer: AVSampleBufferRenderSynchronizer
    private let lock = NSLock()
    private var _events: [Event] = []
    private var _positions: [Position] = []
    private var _flushes: [Flush] = []
    private var _status = TransportStatus.paused
    private var observer: NSObjectProtocol?

    init() throws {
        let box = WeakBox<CheckProbe>()
        transport = Transport { event in box.value?.record(event) }
        guard let synchronizer = reflected(transport, "feeder", "output", "synchronizer") as? AVSampleBufferRenderSynchronizer,
              let renderer = reflected(transport, "feeder", "output", "renderer") as? AVSampleBufferAudioRenderer
        else { throw CheckError("no synchronizer behind Transport; the output's layout changed") }
        self.synchronizer = synchronizer
        box.value = self
        observer = NotificationCenter.default.addObserver(forName: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: renderer, queue: nil) { [weak self] note in
            guard let self else { return }
            let flushTime = (note.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?.timeValue.seconds
            let flush = Flush(host: hostNow(), flushTime: flushTime, clock: synchronizer.currentTime().seconds, latency: Session.shared.outputLatency)
            lock.withLock { self._flushes.append(flush) }
            Log.shared.write("AUTO-FLUSH flushTime \(flushTime.map { fmt($0) } ?? "?") clock \(fmt(flush.clock)) latency \(fmt(flush.latency * 1000, 1)) ms \(Session.outputs)")
        }
    }

    deinit {
        observer.map(NotificationCenter.default.removeObserver)
        transport.stop()
    }

    var events: [Event] { lock.withLock { _events } }
    var positions: [Position] { lock.withLock { _positions } }
    var flushes: [Flush] { lock.withLock { _flushes } }
    var status: TransportStatus { lock.withLock { _status } }
    var clock: Double { synchronizer.currentTime().seconds }

    func events(_ kind: String) -> [Event] { events.filter { $0.kind == kind } }

    /// Latest heard media seconds of `item`, extrapolated from the last position at rate 1.
    var lastPosition: Position? { positions.last }

    /// Host time at which the position of `item` reached `seconds`, interpolated between events.
    func host(item: String, at seconds: Double) -> Double? {
        let mine = positions.filter { $0.item == item }
        guard let i = mine.firstIndex(where: { $0.seconds >= seconds }) else { return nil }
        guard i > 0, mine[i].seconds > mine[i - 1].seconds else { return mine[i].host - (mine[i].seconds - seconds) }
        let (a, b) = (mine[i - 1], mine[i])
        return a.host + (seconds - a.seconds) / (b.seconds - a.seconds) * (b.host - a.host)
    }

    /// Polls until `condition` holds or `cap` seconds pass; returns whether it held.
    @discardableResult
    func until(_ cap: Double, _ condition: (CheckProbe) -> Bool) async throws -> Bool {
        let begin = hostNow()
        while !condition(self) {
            if hostNow() - begin > cap { return false }
            try await pause(0.01)
        }
        return true
    }

    private func record(_ event: TransportEvent<String>) {
        let host = hostNow()
        switch event {
        case let .position(item, frame, sampleRate):
            let position = Position(host: host, item: item, seconds: Double(frame) / sampleRate, clock: clock, latency: Session.shared.outputLatency)
            lock.withLock { _positions.append(position) }
        case let .crossed(item):
            add(Event(host: host, kind: "crossed", detail: item))
        case let .status(status):
            lock.withLock { _status = status }
            add(Event(host: host, kind: "status", detail: "\(status)"))
        case let .failed(item, error):
            add(Event(host: host, kind: "failed", detail: "\(item ?? "output"): \(error)"))
        }
    }

    private func add(_ event: Event) {
        lock.withLock { _events.append(event) }
        Log.shared.write("transport \(event.kind) \(event.detail) clock \(fmt(clock))")
    }
}

final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
}

/// A stored property along `path`, unwrapping optionals; Mirror sees private storage.
func reflected(_ root: Any, _ path: String...) -> Any? {
    func unwrapped(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        return mirror.children.first.flatMap { unwrapped($0.value) }
    }
    var current: Any? = root
    for name in path {
        guard let value = current.flatMap(unwrapped) else { return nil }
        current = Mirror(reflecting: value).children.first { $0.label == name }?.value
    }
    return current.flatMap(unwrapped)
}

/// Resolves once with the first of: a button tap, a matching notification, or the cap.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?
    private var result: String?

    func wait() async -> String {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if let result { continuation.resume(returning: result) } else { self.continuation = continuation }
            }
        }
    }

    func resolve(_ value: String) {
        lock.withLock {
            guard result == nil else { return }
            result = value
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}

@MainActor
final class CheckUI: ObservableObject {
    static let shared = CheckUI()

    struct Prompt {
        let title: String
        let body: String
        let buttons: [String]
        let routePicker: Bool
        let gate: Gate
    }

    @Published private(set) var title = "Starting"
    @Published private(set) var detail = ""
    @Published private(set) var prompt: Prompt?

    func show(_ title: String, _ detail: String) {
        self.title = title
        self.detail = detail
    }

    /// Shows a full-screen prompt until a button, `match` on a session notification, or `cap`; returns
    /// the button label, "fired: <detail>" or "timeout".
    nonisolated func ask(_ title: String, _ body: String, buttons: [String], routePicker: Bool = false, cap: Double,
                         match: (@Sendable (Notification) -> String?)? = nil) async -> String {
        let gate = Gate()
        var observers: [NSObjectProtocol] = []
        if let match {
            let names = [AVAudioSession.routeChangeNotification, AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { note in
                    if let detail = match(note) { gate.resolve("fired: \(detail)") }
                }
            }
        }
        await MainActor.run { prompt = Prompt(title: title, body: body, buttons: buttons, routePicker: routePicker, gate: gate) }
        Task {
            try? await pause(cap)
            gate.resolve("timeout")
        }
        let result = await gate.wait()
        observers.forEach(NotificationCenter.default.removeObserver)
        await MainActor.run { if prompt?.gate === gate { prompt = nil } }
        Log.shared.write("prompt '\(title)': \(result)")
        return result
    }
}

struct CheckView: View {
    @ObservedObject private var ui = CheckUI.shared
    @ObservedObject private var log = Log.shared

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("PlaybackRender check").font(.caption).foregroundStyle(.secondary)
                Text(ui.title).font(.title2.bold())
                Text(ui.detail).font(.body)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(log.lines.suffix(400).enumerated()), id: \.offset) { _, line in
                                Text(line).font(.system(size: 10, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                    }
                    .onChange(of: log.lines.count) { _, _ in proxy.scrollTo("end") }
                }
            }
            .padding()
            if let prompt = ui.prompt {
                VStack(spacing: 28) {
                    Spacer()
                    Text(prompt.title).font(.largeTitle.bold()).multilineTextAlignment(.center)
                    Text(prompt.body).font(.title3).multilineTextAlignment(.center)
                    if prompt.routePicker { RoutePicker().frame(width: 88, height: 88) }
                    Spacer()
                    ForEach(prompt.buttons, id: \.self) { label in
                        Button { prompt.gate.resolve(label) } label: {
                            Text(label).font(.title3).frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.yellow)
            }
        }
        .task { await CheckRun.run() }
    }
}
