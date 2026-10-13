import AVFoundation

/// The `AVAudioSession` category, mode, route-sharing policy and options the player sets at init
/// and again after a media-services reset. The rules that act on session events are the player's.
public struct AudioSessionConfiguration: Sendable {
    #if os(iOS)
    public var category: AVAudioSession.Category
    public var mode: AVAudioSession.Mode
    public var routeSharingPolicy: AVAudioSession.RouteSharingPolicy
    public var options: AVAudioSession.CategoryOptions

    public init(
        category: AVAudioSession.Category = .playback,
        mode: AVAudioSession.Mode = .default,
        routeSharingPolicy: AVAudioSession.RouteSharingPolicy = .longFormAudio,
        options: AVAudioSession.CategoryOptions = []
    ) {
        self.category = category
        self.mode = mode
        self.routeSharingPolicy = routeSharingPolicy
        self.options = options
    }

    // One call carries category, mode and policy together: the policy is only valid set with them.
    func apply(to session: some CategorySetting) throws {
        try session.setCategory(category, mode: mode, policy: routeSharingPolicy, options: options)
    }

    /// Music: `.playback` with long-form route sharing, so the system offers AirPlay 2 and the
    /// long-form route picker.
    public static let longFormAudio = AudioSessionConfiguration()
    /// Speech: as `.longFormAudio` with mode `.spokenAudio`, so another app's prompt pauses the
    /// player instead of ducking it.
    public static let spokenAudio = AudioSessionConfiguration(mode: .spokenAudio)
    #else
    // macOS has no `AVAudioSession`; the presets exist so an app's call compiles on both.
    public static let longFormAudio = AudioSessionConfiguration()
    public static let spokenAudio = AudioSessionConfiguration()
    #endif
}

#if os(iOS)
/// The one `AVAudioSession` call that sets the configuration, so a test can see what reaches it.
protocol CategorySetting {
    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        policy: AVAudioSession.RouteSharingPolicy,
        options: AVAudioSession.CategoryOptions
    ) throws
}

extension AVAudioSession: CategorySetting {}
#endif

/// What the session reports, on the main actor.
@_spi(Testing) public enum AudioSessionEvent: Equatable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeChanged(reason: AudioRouteChangeReason, previous: [AudioPortKind], current: [AudioPortKind])
    case mediaServicesReset
}

@_spi(Testing) public enum AudioRouteChangeReason: Equatable {
    case newDeviceAvailable, oldDeviceUnavailable, other
}

/// An output port, by the kind that decides whether losing it pauses. Bluetooth A2DP, LE and HFP
/// are one kind, so a profile switch loses nothing.
@_spi(Testing) public enum AudioPortKind: Equatable {
    case builtIn, headphones, bluetooth, usb, lineOut, carAudio, airPlay, other

    /// Audio meant for the listener alone: losing it would move playback onto the speaker, media3's
    /// "becoming noisy".
    var isPersonal: Bool {
        switch self {
        case .headphones, .bluetooth, .usb, .lineOut, .carAudio, .airPlay: true
        case .builtIn, .other: false
        }
    }
}

/// The one edge to `AVAudioSession`: `SystemAudioSession` on device, a fake in tests.
@MainActor
@_spi(Testing) public protocol AudioSessionControlling: AnyObject {
    /// Applies the configuration; called at init and after a media-services reset.
    func configure()
    /// Activates the session off the main thread and answers on the main actor, with the error if
    /// it failed. A configuration that failed to apply is applied again first, so its error lands here.
    func activate(completion: @escaping @MainActor ((any Error)?) -> Void)
    /// Deactivates with `notifyOthersOnDeactivation`, after any activation still running.
    func deactivate()
    func setEventHandler(_ handler: @escaping @MainActor (AudioSessionEvent) -> Void)
}
