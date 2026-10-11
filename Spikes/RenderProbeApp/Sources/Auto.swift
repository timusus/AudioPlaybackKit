import AVFoundation
import MediaPlayer
import UIKit

/// Unattended run: every automatable test in turn, each under a timeout, then `results.json` and a
/// `done` flag in Documents for run-auto.sh to poll and copy back.
enum AutoRun {
    static let enabled = CommandLine.arguments.contains("--auto") || ProcessInfo.processInfo.environment["RENDERPROBE_AUTO"] != nil

    /// `--only=Q1a,Q2` runs a subset, for iterating on one test without the full run.
    static let only: Set<String>? = CommandLine.arguments.first { $0.hasPrefix("--only=") }
        .map { Set($0.dropFirst("--only=".count).split(separator: ",").map(String.init)) }

    nonisolated(unsafe) static var current = ""

    struct Test {
        let id: String
        let question: String
        let timeout: Double
        let needsMic: Bool
        let run: @Sendable () async throws -> [String: Any]
    }

    struct TimedOut: Error {}

    static func run() async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let resultsURL = documents.appendingPathComponent("results.json")
        let doneURL = documents.appendingPathComponent("done")
        try? FileManager.default.removeItem(at: resultsURL)
        try? FileManager.default.removeItem(at: doneURL)
        let started = Date()
        Log.shared.write("AUTO run start")

        let mic = await micPermission()
        Log.shared.write("mic permission: \(mic)")
        let (model, version) = await MainActor.run { (UIDevice.current.model, UIDevice.current.systemVersion) }
        var waited = 0
        while waited < 50, await MainActor.run(body: { UIApplication.shared.applicationState != .active }) {
            try? await pause(0.1)
            waited += 1
        }
        try? await pause(1)
        let originalVolume = Session.shared.outputVolume
        await setVolume(0.75)
        try? await pause(1)
        Log.shared.write("volume \(fmt(Double(originalVolume), 2)) -> \(fmt(Double(Session.shared.outputVolume), 2))")
        let header: [String: Any] = ["device": model, "ios": version, "started": ISO8601DateFormatter().string(from: started), "micPermission": mic,
                                     "volume": Session.shared.outputVolume, "originalVolume": originalVolume]
        var results: [[String: Any]] = []
        for test in AutoProbes.all where only?.contains(test.id) ?? true {
            current = test.id
            let begin = Log.shared.now
            let state = await MainActor.run {
                // Run 3 still auto-locked 75 s in with the flag set once; re-arming it per test keeps the screen on.
                UIApplication.shared.isIdleTimerDisabled = false
                UIApplication.shared.isIdleTimerDisabled = true
                return UIApplication.shared.applicationState == .active ? "active" : UIApplication.shared.applicationState == .background ? "background" : "inactive"
            }
            Log.shared.write("=== AUTO \(test.id) \(test.question) === app \(state), volume \(fmt(Double(Session.shared.outputVolume), 2))")
            var entry: [String: Any] = ["id": test.id, "question": test.question]
            if test.needsMic, mic != "granted" {
                entry["status"] = "skipped"
                entry["verdict"] = "mic permission \(mic)"
            } else {
                do {
                    let outcome = try await withTimeout(test.timeout, test.run)
                    entry.merge(outcome) { _, new in new }
                } catch is TimedOut {
                    entry["status"] = "timeout"
                    entry["verdict"] = "no result within \(Int(test.timeout)) s"
                } catch {
                    entry["status"] = "error"
                    entry["verdict"] = "\(error)"
                }
            }
            entry["seconds"] = round3(Log.shared.now - begin)
            Log.shared.write("AUTO \(test.id): \(entry["status"] ?? "?") - \(entry["verdict"] ?? "")")
            results.append(entry)
            // Write after every test, so a crash later still leaves what was measured.
            write(header.merging(["complete": false, "tests": results]) { a, _ in a }, to: resultsURL)
        }
        write(header.merging(["complete": true, "tests": results]) { a, _ in a }, to: resultsURL)
        Log.shared.write("AUTO run done in \(fmt(Date().timeIntervalSince(started), 0)) s")
        await setVolume(originalVolume)
        FileManager.default.createFile(atPath: doneURL.path, contents: Data("done\n".utf8))
        try? await pause(1)
        exit(0)
    }

    /// Asks once; nobody may be at the phone to answer, so an unanswered prompt counts as not granted.
    static func micPermission() async -> String {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return "granted"
        case .denied: return "denied"
        default: break
        }
        let granted = try? await withTimeout(45) {
            await withCheckedContinuation { done in AVAudioApplication.requestRecordPermission { done.resume(returning: $0) } }
        }
        return granted.map { $0 ? "granted" : "denied" } ?? "unanswered"
    }

    /// The mic tests need the speaker audible and nobody is there to press volume up; MPVolumeView's slider is
    /// the only way an app can set the system volume.
    @MainActor static func setVolume(_ value: Float) async {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.windows.first }.first
        let view = volumeView ?? MPVolumeView(frame: CGRect(x: -200, y: -200, width: 100, height: 40))
        volumeView = view
        if view.superview == nil {
            window?.addSubview(view)
            // The slider only appears once the view has been in a window for a layout pass.
            try? await pause(0.5)
        }
        view.layoutIfNeeded()
        if window == nil { Log.shared.write("no window for MPVolumeView") }
        let slider = view.subviews.compactMap { $0 as? UISlider }.first
        slider?.setValue(value, animated: false)
        slider?.sendActions(for: .valueChanged)
        if slider == nil { Log.shared.write("no MPVolumeView slider; volume unchanged") }
    }

    @MainActor private static var volumeView: MPVolumeView?

    /// Logs lifecycle changes, since a backgrounded app cannot reactivate a non-mixable session.
    @MainActor static func observeLifecycle() {
        let names: [(Notification.Name, String)] = [
            (UIApplication.willResignActiveNotification, "willResignActive"), (UIApplication.didEnterBackgroundNotification, "didEnterBackground"),
            (UIApplication.didBecomeActiveNotification, "didBecomeActive"), (UIApplication.protectedDataWillBecomeUnavailableNotification, "protectedDataUnavailable"),
        ]
        for (name, label) in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Log.shared.write("APP \(label)")
                Events.shared.add("app", label)
                // Set before the app is active, the flag does not stop auto-lock; toggling re-arms it.
                if name == UIApplication.didBecomeActiveNotification {
                    UIApplication.shared.isIdleTimerDisabled = false
                    UIApplication.shared.isIdleTimerDisabled = true
                }
            }
        }
    }

    private static func write(_ object: [String: Any], to url: URL) {
        let clean = sanitize(object)
        do {
            try JSONSerialization.data(withJSONObject: clean, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        } catch {
            Log.shared.write("results.json write failed: \(error)")
        }
    }

    /// JSON has no NaN or infinity; those become null.
    private static func sanitize(_ value: Any) -> Any {
        switch value {
        case let d as Double: return d.isFinite ? d : NSNull()
        case let f as Float: return f.isFinite ? Double(f) : NSNull()
        case let dict as [String: Any]: return dict.mapValues(sanitize)
        case let array as [Any]: return array.map(sanitize)
        default: return value
        }
    }
}

/// Runs `body` in its own task and returns whichever comes first, the result or the timeout; a body that
/// ignores cancellation is abandoned rather than awaited, so one hang cannot stall the run.
func withTimeout<T>(_ seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    let once = Once()
    var work: Task<Void, Never>?
    let result: T = try await withCheckedThrowingContinuation { continuation in
        work = Task {
            do {
                let value = try await body()
                if once.claim() { continuation.resume(returning: value) }
            } catch {
                if once.claim() { continuation.resume(throwing: error) }
            }
        }
        Task {
            try? await pause(seconds)
            if once.claim() { continuation.resume(throwing: AutoRun.TimedOut()) }
        }
    }
    work?.cancel()
    return result
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
