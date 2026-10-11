import AVFoundation

#if os(iOS)
/// `AVAudioSession.sharedInstance()` behind the seam. Category and activation calls block for tens
/// of milliseconds, so they run in call order on one serial queue, never on the main thread.
@MainActor
final class SystemAudioSession: AudioSessionControlling {
    private let configuration: AudioSessionConfiguration
    private let queue = DispatchQueue(label: "PlaybackPlayer.SystemAudioSession")
    private var observers: [any NSObjectProtocol] = []
    private var handler: (@MainActor (AudioSessionEvent) -> Void)?

    init(configuration: AudioSessionConfiguration) {
        self.configuration = configuration
        let center = NotificationCenter.default
        let names = [
            AVAudioSession.interruptionNotification,
            AVAudioSession.routeChangeNotification,
            AVAudioSession.mediaServicesWereResetNotification,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let event = Self.event(note) else { return }
                    self.handler?(event)
                }
            }
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func configure() {
        // A failure here is retried, and reported, by the next activation.
        queue.async { [configuration] in try? Self.apply(configuration) }
    }

    func activate(completion: @escaping @MainActor ((any Error)?) -> Void) {
        queue.async { [configuration] in
            var failure: (any Error)?
            do {
                try Self.apply(configuration)
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                failure = error
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(failure) } }
        }
    }

    func deactivate() {
        // Nothing to do on a failure: playback has stopped, and the next play activates again.
        queue.async { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    func setEventHandler(_ handler: @escaping @MainActor (AudioSessionEvent) -> Void) {
        self.handler = handler
    }

    private nonisolated static func apply(_ configuration: AudioSessionConfiguration) throws {
        try AVAudioSession.sharedInstance().setCategory(
            configuration.category,
            mode: configuration.mode,
            policy: configuration.routeSharingPolicy,
            options: configuration.options
        )
    }

    private static func event(_ note: Notification) -> AudioSessionEvent? {
        let info = note.userInfo ?? [:]
        switch note.name {
        case AVAudioSession.interruptionNotification:
            guard let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return nil }
            switch type {
            case .began:
                return .interruptionBegan
            case .ended:
                let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
                return .interruptionEnded(shouldResume: options?.contains(.shouldResume) ?? false)
            @unknown default:
                return nil
            }
        case AVAudioSession.routeChangeNotification:
            let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason: AudioRouteChangeReason = switch raw.flatMap(AVAudioSession.RouteChangeReason.init) {
            case .newDeviceAvailable: .newDeviceAvailable
            case .oldDeviceUnavailable: .oldDeviceUnavailable
            default: .other
            }
            let previous = info[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            // The notification carries only the old route; a newer one read here posts its own change.
            return .routeChanged(
                reason: reason,
                previous: kinds(previous),
                current: kinds(AVAudioSession.sharedInstance().currentRoute)
            )
        case AVAudioSession.mediaServicesWereResetNotification:
            return .mediaServicesReset
        default:
            return nil
        }
    }

    private static func kinds(_ route: AVAudioSessionRouteDescription?) -> [AudioPortKind] {
        (route?.outputs ?? []).map { output in
            switch output.portType {
            case .builtInSpeaker, .builtInReceiver: .builtIn
            case .headphones: .headphones
            case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: .bluetooth
            case .usbAudio: .usb
            case .lineOut: .lineOut
            case .carAudio: .carAudio
            case .airPlay: .airPlay
            default: .other
            }
        }
    }
}
#else
/// macOS has no session to manage: activation always succeeds and nothing is reported.
@MainActor
final class SystemAudioSession: AudioSessionControlling {
    init(configuration: AudioSessionConfiguration) {}
    func configure() {}
    func activate(completion: @escaping @MainActor ((any Error)?) -> Void) { completion(nil) }
    func deactivate() {}
    func setEventHandler(_ handler: @escaping @MainActor (AudioSessionEvent) -> Void) {}
}
#endif
