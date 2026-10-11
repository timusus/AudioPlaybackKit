import AVFoundation

enum Session {
    static var shared: AVAudioSession { .sharedInstance() }

    /// Called when an interruption ends and the system says to resume.
    nonisolated(unsafe) static var onResume: (@Sendable () -> Void)?

    static func configure(longForm: Bool, preferredRate: Double? = nil) throws {
        try? shared.setActive(false, options: [])
        try shared.setCategory(.playback, mode: .default, policy: longForm ? .longFormAudio : .default, options: [])
        if let preferredRate { try shared.setPreferredSampleRate(preferredRate) }
        try shared.setActive(true)
        let preferred = preferredRate.map { fmt($0, 0) } ?? "unset"
        Log.shared.write("session .playback longForm=\(longForm) preferredRate=\(preferred): \(snapshot)")
    }

    /// Speaker playback with the mic open and no voice processing, so the mic hears the renderer as is.
    static func configureMeasurement(preferredRate: Double? = nil) throws {
        try? shared.setActive(false, options: [])
        try shared.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        if let preferredRate { try shared.setPreferredSampleRate(preferredRate) }
        try shared.setActive(true)
        Log.shared.write("session .playAndRecord .measurement preferredRate=\(preferredRate.map { fmt($0, 0) } ?? "unset"): \(snapshot) inputLatency=\(fmt(shared.inputLatency * 1000, 1))ms")
    }

    static var category: String { shared.category == .playAndRecord ? "playAndRecord" : shared.category == .playback ? "playback" : shared.category.rawValue }

    static var snapshot: String {
        "hwRate=\(fmt(shared.sampleRate, 0)) ioBuffer=\(fmt(shared.ioBufferDuration * 1000, 1))ms outputLatency=\(fmt(shared.outputLatency * 1000, 1))ms outputs=\(outputs)"
    }

    static var outputs: String {
        let ports = shared.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }
        return ports.isEmpty ? "none" : ports.joined(separator: ",")
    }

    /// Logs route changes and interruptions for the whole run, whichever test is playing.
    static func installMonitor() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw).map(describe) ?? "?"
            let previous = (note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)?
                .outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",") ?? "?"
            Log.shared.write("ROUTE CHANGE \(reason): \(previous) -> \(snapshot)")
            Events.shared.add("routeChange", "\(reason) hwRate=\(fmt(shared.sampleRate, 0)) outputs=\(outputs)")
        }
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { note in
            let info = note.userInfo
            let type = AVAudioSession.InterruptionType(rawValue: info?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0)
            let reason = info?[AVAudioSessionInterruptionReasonKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            Log.shared.write("INTERRUPTION \(type == .began ? "began" : "ended") reasonRaw=\(reason) shouldResume=\(options.contains(.shouldResume))")
            Events.shared.add("interruption", "\(type == .began ? "began" : "ended") shouldResume=\(options.contains(.shouldResume))")
            if type == .ended, options.contains(.shouldResume) { onResume?() }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { _ in
            Log.shared.write("MEDIA SERVICES RESET")
            Events.shared.add("mediaServicesReset", "")
        }
    }

    private static func describe(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .newDeviceAvailable: "newDeviceAvailable"
        case .oldDeviceUnavailable: "oldDeviceUnavailable"
        case .categoryChange: "categoryChange"
        case .override: "override"
        case .wakeFromSleep: "wakeFromSleep"
        case .noSuitableRouteForCategory: "noSuitableRouteForCategory"
        case .routeConfigurationChange: "routeConfigurationChange"
        default: "unknown(\(reason.rawValue))"
        }
    }
}
