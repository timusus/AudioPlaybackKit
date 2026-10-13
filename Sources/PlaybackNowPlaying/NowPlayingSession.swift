import Foundation
import MediaPlayer
import Observation
import PlaybackPlayer

/// How far the system's extrapolated elapsed time may stray from the heard position before it is
/// rewritten. On an iPhone the output's clock started up to 0.2 s after a play on a fresh renderer and
/// lost about 0.1 s on a rate change; a resume of a running renderer lost 0.04 s, left unwritten.
private let maxDrift: TimeInterval = 0.05

/// The latest session to take each info centre, keyed by the centre's identity: the system's is one
/// object, and a test's fake centres are its own, so parallel tests never share a claim.
@MainActor private var centreClaims: [ObjectIdentifier: Int] = [:]
@MainActor private var claims = 0

/// What the lock screen, Control Centre and CarPlay show for an item.
public struct NowPlayingMetadata: Sendable {
    public var title: String
    public var artist: String?
    public var album: String?
    /// Shown until the player has opened the item; the player's own duration wins once known.
    public var duration: TimeInterval?

    public init(title: String, artist: String? = nil, album: String? = nil, duration: TimeInterval? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}

/// Shows a `Player`, or an app's wrapper of one, in `MPNowPlayingInfoCenter` and routes
/// `MPRemoteCommandCenter` back to it, until `release()`. Elapsed time and rate are written only on a
/// jump of the player's position, a pause or play, a rate change, an item change, or when what is heard
/// strays from where the system has extrapolated it (the output started late). A remote command is
/// enabled only while the player's `availableCommands` has it, as a media3 session offers a controller;
/// `skipIntervals` adds the skip buttons, which the lock screen draws over next and previous. One
/// session per app, since both centres are global.
@MainActor
public final class NowPlayingSession<Item: Hashable & Sendable> {
    let player: any NowPlayingControllable<Item>
    private let supportedRates: [Double]
    private let metadata: @MainActor (Item) -> NowPlayingMetadata
    private let artwork: (@MainActor (Item) async -> MPMediaItemArtwork?)?
    private let infoCenter: any NowPlayingInfoCenter
    private let commandCenter: any RemoteCommandCenter
    /// Seconds on a monotonic clock, to tell how far the system has extrapolated elapsed time.
    private let now: () -> TimeInterval
    /// This session's entry in `centreClaims`, so a clear from it cannot undo a newer session's install.
    private let claim: Int

    @_spi(Testing) public private(set) var pendingRefresh: Task<Void, Never>?
    private(set) var artworkLoad: Task<Void, Never>?
    private var released = false
    private var enabledCommands: Set<RemoteCommand>?
    /// The outer optional is unset until the first write.
    private var shownIntervals: SkipIntervals??
    private var current: (item: Item, metadata: NowPlayingMetadata, artwork: MPMediaItemArtwork?)?
    private var published: Published?
    /// The player's position at the previous refresh, to tell a held position from a moving one.
    private var lastRead: TimeInterval?
    /// Tells one artwork load from another for the same item, so only the latest publishes.
    private var artworkLoads = 0

    /// What was last written, and when. Position is compared only with where the system has
    /// extrapolated it to: a jump moves the player's `discontinuityCount`.
    private struct Published {
        var item: Item
        var rate: Double
        var defaultRate: Double
        var duration: TimeInterval?
        var isLive: Bool
        var state: MPNowPlayingPlaybackState
        var discontinuity: Int
        var position: TimeInterval
        var at: TimeInterval

        /// A held position (`other.position` as last read) is not drift: the output has not started yet,
        /// and the write that follows its first move corrects the system's extrapolation once.
        func sameShown(as other: Published, held: Bool) -> Bool {
            item == other.item && rate == other.rate && defaultRate == other.defaultRate
                && duration == other.duration && isLive == other.isLive && state == other.state
                && discontinuity == other.discontinuity
                && (held || abs(position + rate * (other.at - at) - other.position) <= maxDrift)
        }
    }

    /// `supportedRates` enables the rate command with those rates; empty leaves it off. `artwork` runs
    /// once per item change, and what it returns is dropped if the item changed meanwhile.
    public convenience init(
        player: any NowPlayingControllable<Item>,
        supportedRates: [Double] = [],
        metadata: @escaping @MainActor (Item) -> NowPlayingMetadata,
        artwork: (@MainActor (Item) async -> MPMediaItemArtwork?)? = nil
    ) {
        self.init(
            player: player, supportedRates: supportedRates, metadata: metadata, artwork: artwork,
            infoCenter: MPNowPlayingInfoCenter.default(), commandCenter: SystemRemoteCommandCenter()
        )
    }

    @_spi(Testing) public init(
        player: any NowPlayingControllable<Item>,
        supportedRates: [Double],
        metadata: @escaping @MainActor (Item) -> NowPlayingMetadata,
        artwork: (@MainActor (Item) async -> MPMediaItemArtwork?)?,
        infoCenter: any NowPlayingInfoCenter,
        commandCenter: any RemoteCommandCenter,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.now = now
        self.player = player
        self.supportedRates = supportedRates
        self.metadata = metadata
        self.artwork = artwork
        self.infoCenter = infoCenter
        self.commandCenter = commandCenter
        claims += 1
        claim = claims
        centreClaims[ObjectIdentifier(infoCenter)] = claim
        if !supportedRates.isEmpty { commandCenter.setSupportedRates(supportedRates) }
        observe()
    }

    // Both centres are global, so a dropped session would leave its handlers and info behind. A hop
    // rather than `isolated deinit` (Swift 6 only): the centres are main-actor classes, so the task
    // captures them, not `self`. The pending tasks hold `self` weakly and end with it.
    deinit {
        guard !released else { return }
        let commandCenter = commandCenter, infoCenter = infoCenter, claim = claim
        Task { @MainActor in Self.clear(commandCenter, infoCenter, claim: claim) }
    }

    /// Disables every command and clears the info, rates and skip intervals, as media3's
    /// `MediaSession.release`. Final. Dropping the session does the same, one main-actor turn later.
    /// Either leaves the centres alone once a newer session has taken them.
    public func release() {
        guard !released else { return }
        released = true
        pendingRefresh?.cancel()
        artworkLoad?.cancel()
        Self.clear(commandCenter, infoCenter, claim: claim)
    }

    /// Asks `metadata` and `artwork` again for the current item and shows the result, for an app that
    /// edited the item's tags. Elapsed time, rate and commands are left alone; the old artwork stays
    /// until the new one arrives, and a nil from `artwork` clears it. Does nothing with no current item,
    /// once the info was cleared elsewhere, or after `release()`.
    public func refreshMetadata() {
        guard !released, let item = current?.item, player.currentItem == item,
              var info = infoCenter.nowPlayingInfo, var shown = published else { return }
        let shownArtwork = current?.artwork
        load(item)
        current?.artwork = shownArtwork
        guard let current else { return }
        shown.duration = player.isLive ? nil : player.duration ?? current.metadata.duration
        published = shown
        info[MPMediaItemPropertyTitle] = current.metadata.title
        info[MPMediaItemPropertyArtist] = current.metadata.artist
        info[MPMediaItemPropertyAlbumTitle] = current.metadata.album
        info[MPMediaItemPropertyPlaybackDuration] = shown.duration
        infoCenter.nowPlayingInfo = info
    }

    private static func clear(_ commandCenter: any RemoteCommandCenter, _ infoCenter: any NowPlayingInfoCenter, claim: Int) {
        let key = ObjectIdentifier(infoCenter)
        guard centreClaims[key] == claim else { return }
        centreClaims[key] = nil
        for command in RemoteCommand.allCases { commandCenter.setHandler(for: command, nil) }
        commandCenter.setSupportedRates([])
        commandCenter.setSkipIntervals(nil)
        infoCenter.nowPlayingInfo = nil
        infoCenter.playbackState = .stopped
    }

    // MARK: Observation

    // `onChange` fires once per tracking, on the player's willSet; the task reads after the change and
    // folds every change made before it runs into one refresh.
    private func observe() {
        guard !released else { return }
        withObservationTracking {
            refresh()
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingRefresh = Task { [weak self] in self?.observe() }
            }
        }
    }

    private func refresh() {
        applyCommands()
        guard let item = player.currentItem else {
            artworkLoad?.cancel()
            current = nil
            published = nil
            lastRead = nil
            guard infoCenter.playbackState != .stopped || infoCenter.nowPlayingInfo != nil else { return }
            infoCenter.nowPlayingInfo = nil
            infoCenter.playbackState = .stopped
            return
        }
        if current?.item != item { load(item) }
        let next = snapshot(of: item)
        let held = lastRead == next.position
        lastRead = next.position
        if published.map({ !$0.sameShown(as: next, held: held) }) ?? true { publish(next) }
    }

    private func load(_ item: Item) {
        current = (item, metadata(item), nil)
        artworkLoad?.cancel()
        artworkLoad = nil
        guard let artwork else { return }
        artworkLoads += 1
        let id = artworkLoads
        artworkLoad = Task { [weak self] in
            let image = await artwork(item)
            guard let self, !released, artworkLoads == id, current?.item == item, player.currentItem == item else { return }
            current?.artwork = image
            publish(snapshot(of: item))
        }
    }

    // MARK: Info

    // media3 `Util.shouldShowPlayButton`: a pause, an idle or ended player or a suppression shows play.
    private var showsPlay: Bool {
        !player.playWhenReady || player.state == .idle || player.state == .ended || player.suppression != .unsuppressed
    }

    private func snapshot(of item: Item) -> Published {
        Published(
            item: item,
            rate: player.isPlaying ? player.rate : 0,
            defaultRate: player.rate,
            duration: player.isLive ? nil : player.duration ?? current?.metadata.duration,
            isLive: player.isLive,
            state: showsPlay ? .paused : .playing,
            discontinuity: player.discontinuityCount,
            position: player.position,
            at: now()
        )
    }

    private func publish(_ shown: Published) {
        published = shown
        var info: [String: Any] = [
            MPNowPlayingInfoPropertyElapsedPlaybackTime: shown.position,
            MPNowPlayingInfoPropertyPlaybackRate: shown.rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: shown.defaultRate,
            MPNowPlayingInfoPropertyIsLiveStream: shown.isLive,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let current {
            info[MPMediaItemPropertyTitle] = current.metadata.title
            info[MPMediaItemPropertyArtist] = current.metadata.artist
            info[MPMediaItemPropertyAlbumTitle] = current.metadata.album
            info[MPMediaItemPropertyArtwork] = current.artwork
        }
        info[MPMediaItemPropertyPlaybackDuration] = shown.duration
        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = shown.state
    }

    // MARK: Commands

    // iOS draws skip buttons over next and previous when both are enabled, so `skipIntervals` only picks
    // what is drawn; next and previous stay registered for steering wheels and headphones that send only them.
    private var remoteCommands: Set<RemoteCommand> {
        let available = player.availableCommands
        var commands: Set<RemoteCommand> = []
        if available.contains(.playPause) { commands.formUnion([.play, .pause, .togglePlayPause]) }
        if available.contains(.seekToNext) { commands.insert(.nextTrack) }
        if available.contains(.seekToPrevious) { commands.insert(.previousTrack) }
        if player.skipIntervals != nil {
            if available.contains(.seekForward) { commands.insert(.skipForward) }
            if available.contains(.seekBack) { commands.insert(.skipBackward) }
        }
        if available.contains(.seekInCurrentItem) { commands.insert(.changePlaybackPosition) }
        if available.contains(.setRate), !supportedRates.isEmpty { commands.insert(.changePlaybackRate) }
        return commands
    }

    private func applyCommands() {
        let intervals = player.skipIntervals
        if shownIntervals != .some(intervals) {
            shownIntervals = intervals
            commandCenter.setSkipIntervals(intervals.map { ($0.forward, $0.backward) })
        }
        let available = remoteCommands
        for command in RemoteCommand.allCases {
            let enable = available.contains(command)
            guard enabledCommands.map({ $0.contains(command) != enable }) ?? true else { continue }
            commandCenter.setHandler(for: command, enable ? { [weak self] in self?.handle(command, $0) ?? .commandFailed } : nil)
        }
        enabledCommands = available
    }

    private func handle(_ command: RemoteCommand, _ event: RemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard player.currentItem != nil else { return .noActionableNowPlayingItem }
        // The handlers follow a change only on the next refresh; a press in between is refused, as media3 does.
        guard remoteCommands.contains(command) else { return .commandFailed }
        switch (command, event) {
        case (.play, _): player.play()
        case (.pause, _): player.pause()
        // media3's `playIfSuppressed` default: a suppressed player shows play, so toggle plays.
        case (.togglePlayPause, _): showsPlay ? player.play() : player.pause()
        case (.nextTrack, _): player.seekToNext()
        case (.previousTrack, _): player.seekToPrevious()
        case let (.skipForward, .interval(seconds)): player.seek(by: seconds)
        case let (.skipBackward, .interval(seconds)): player.seek(by: -seconds)
        case let (.changePlaybackPosition, .position(seconds)): player.seek(to: seconds)
        case let (.changePlaybackRate, .rate(rate)): player.rate = rate
        default: return .commandFailed
        }
        return .success
    }
}
