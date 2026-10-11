import Foundation

/// Every line goes to the screen and to a file in Documents, stamped with seconds since launch.
final class Log: ObservableObject, @unchecked Sendable {
    static let shared = Log()

    @Published private(set) var lines: [String] = []
    let fileURL: URL
    private let origin = Date()
    private let lock = NSLock()
    private let handle: FileHandle?

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stamp = ISO8601DateFormatter().string(from: origin).replacingOccurrences(of: ":", with: "")
        // A fixed name in auto mode, so run-auto.sh knows what to copy back.
        fileURL = documents.appendingPathComponent(CheckRun.enabled ? "check.log" : AutoRun.enabled ? "auto.log" : "renderprobe-\(stamp).log")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
    }

    var now: Double { Date().timeIntervalSince(origin) }

    func write(_ message: String) {
        let line = lock.withLock { () -> String in
            let line = String(format: "%8.3f ", now) + message
            handle?.write(Data((line + "\n").utf8))
            return line
        }
        DispatchQueue.main.async { self.lines.append(line) }
    }
}

func fmt(_ value: Double, _ digits: Int = 3) -> String { String(format: "%.\(digits)f", value) }

/// Wall-clock milliseconds one call takes.
func milliseconds(_ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
}

func pause(_ seconds: Double) async throws {
    try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
}
