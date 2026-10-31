import Foundation
import MediaPlayer
import PlaybackPlayer
@_spi(Testing) import PlaybackNowPlaying

/// Stands in for `MPNowPlayingInfoCenter`: records each write; `info` reads one key of the last.
@MainActor
public final class FakeNowPlayingInfoCenter {
    public var nowPlayingInfo: [String: Any]? {
        didSet { writes += 1 }
    }

    public var playbackState: MPNowPlayingPlaybackState = .unknown
    public private(set) var writes = 0

    public init() {}

    public subscript<T>(_ key: String) -> T? { nowPlayingInfo?[key] as? T }
}

@_spi(Testing) extension FakeNowPlayingInfoCenter: NowPlayingInfoCenter {}

/// Stands in for `MPRemoteCommandCenter`: keeps each command's handler, so a command is enabled
/// exactly while it has one, and `press` runs it as the lock screen would.
@MainActor
public final class FakeRemoteCommandCenter {
    private var handlers: [RemoteCommand: (RemoteCommandEvent) -> MPRemoteCommandHandlerStatus] = [:]
    /// The intervals drawn in the skip glyphs, nil while cleared.
    public private(set) var intervals: (forward: TimeInterval, backward: TimeInterval)?
    /// Nil until the session sets them; empty once cleared.
    public private(set) var rates: [Double]?

    public init() {}

    public var enabled: Set<RemoteCommand> { Set(handlers.keys) }

    /// What the handler answered, or nil for a disabled command, which the system would not send.
    @discardableResult
    public func press(_ command: RemoteCommand, _ event: RemoteCommandEvent = .plain) -> MPRemoteCommandHandlerStatus? {
        handlers[command]?(event)
    }
}

@_spi(Testing) extension FakeRemoteCommandCenter: RemoteCommandCenter {
    public func setHandler(for command: RemoteCommand, _ handler: ((RemoteCommandEvent) -> MPRemoteCommandHandlerStatus)?) {
        handlers[command] = handler
    }

    public func setSkipIntervals(_ intervals: (forward: TimeInterval, backward: TimeInterval)?) {
        self.intervals = intervals
    }

    public func setSupportedRates(_ rates: [Double]) {
        self.rates = rates
    }
}

public extension NowPlayingSession {
    /// A session that publishes to the fakes in place of the system centres. `now` is its monotonic
    /// clock in seconds: move it with the output's, as `PlayerTestRig.run(for:)` moves that.
    convenience init(
        player: any NowPlayingControllable<Item>,
        supportedRates: [Double] = [],
        metadata: @escaping @MainActor (Item) -> NowPlayingMetadata,
        artwork: (@MainActor (Item) async -> MPMediaItemArtwork?)? = nil,
        infoCenter: FakeNowPlayingInfoCenter,
        commandCenter: FakeRemoteCommandCenter,
        now: @escaping () -> TimeInterval
    ) {
        self.init(
            player: player, supportedRates: supportedRates, metadata: metadata, artwork: artwork,
            infoCenter: infoCenter as any NowPlayingInfoCenter, commandCenter: commandCenter as any RemoteCommandCenter,
            now: now
        )
    }

    /// Waits for the refresh the player's last change scheduled: the session reads the player on a
    /// later main-actor turn, so a test reading the fakes before this sees the previous state.
    func settle() async {
        await pendingRefresh?.value
    }
}
