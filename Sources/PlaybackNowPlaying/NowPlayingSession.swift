import Foundation
import MediaPlayer
import Observation
import PlaybackPlayer

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

/// Shows a `Player` in `MPNowPlayingInfoCenter` and routes `MPRemoteCommandCenter` back to it, until
/// `release()`. Elapsed time and rate are written only on a jump of the player's position, a pause or
/// play, a rate change or an item change; the system extrapolates between them. A command is enabled
/// only while it applies, as media3's available commands: next while there is a next, previous on any
/// item but a live one with nothing before it, skips and scrubbing while the item is seekable, play and
/// pause always. One session per app, since both centres are global.
@MainActor
public final class NowPlayingSession<Item: Hashable & Sendable> {
    public enum SkipMode: Equatable, Sendable {
        /// Next and previous item, for music.
        case tracks
        /// Seek by these seconds within the item, for spoken word.
        case intervals(forward: TimeInterval, backward: TimeInterval)
    }

    public var skipMode: SkipMode {
        didSet {
            guard !released, skipMode != oldValue else { return }
            applySkipIntervals()
            applyCommands()
        }
    }

    let player: Player<Item>
    private let supportedRates: [Double]
    private let metadata: @MainActor (Item) -> NowPlayingMetadata
    private let artwork: (@MainActor (Item) async -> MPMediaItemArtwork?)?
    private let infoCenter: any NowPlayingInfoCenter
    private let commandCenter: any RemoteCommandCenter

    private(set) var pendingRefresh: Task<Void, Never>?
    private(set) var artworkLoad: Task<Void, Never>?
    private var released = false
    private var enabledCommands: Set<RemoteCommand>?
    private var current: (item: Item, metadata: NowPlayingMetadata, artwork: MPMediaItemArtwork?)?
    private var published: Published?
    /// Tells one artwork load from another for the same item, so only the latest publishes.
    private var artworkLoads = 0

    /// What was last written. Position is not compared: the system extrapolates it, and a jump moves
    /// the player's `discontinuityCount`.
    private struct Published {
        var item: Item
        var rate: Double
        var defaultRate: Double
        var duration: TimeInterval?
        var isLive: Bool
        var state: MPNowPlayingPlaybackState
        var discontinuity: Int
        var position: TimeInterval

        func sameShown(as other: Published) -> Bool {
            item == other.item && rate == other.rate && defaultRate == other.defaultRate
                && duration == other.duration && isLive == other.isLive && state == other.state
                && discontinuity == other.discontinuity
        }
    }

    /// `supportedRates` enables the rate command with those rates; empty leaves it off. `artwork` runs
    /// once per item change, and what it returns is dropped if the item changed meanwhile.
    public convenience init(
        player: Player<Item>,
        skipMode: SkipMode = .tracks,
        supportedRates: [Double] = [],
        metadata: @escaping @MainActor (Item) -> NowPlayingMetadata,
        artwork: (@MainActor (Item) async -> MPMediaItemArtwork?)? = nil
    ) {
        self.init(
            player: player, skipMode: skipMode, supportedRates: supportedRates, metadata: metadata, artwork: artwork,
            infoCenter: MPNowPlayingInfoCenter.default(), commandCenter: SystemRemoteCommandCenter()
        )
    }

    init(
        player: Player<Item>,
        skipMode: SkipMode,
        supportedRates: [Double],
        metadata: @escaping @MainActor (Item) -> NowPlayingMetadata,
        artwork: (@MainActor (Item) async -> MPMediaItemArtwork?)?,
        infoCenter: any NowPlayingInfoCenter,
        commandCenter: any RemoteCommandCenter
    ) {
        self.player = player
        self.skipMode = skipMode
        self.supportedRates = supportedRates
        self.metadata = metadata
        self.artwork = artwork
        self.infoCenter = infoCenter
        self.commandCenter = commandCenter
        if !supportedRates.isEmpty { commandCenter.setSupportedRates(supportedRates) }
        applySkipIntervals()
        observe()
    }

    /// Disables every command and clears the info, rates and skip intervals, as media3's
    /// `MediaSession.release`. Final.
    public func release() {
        guard !released else { return }
        released = true
        pendingRefresh?.cancel()
        artworkLoad?.cancel()
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
            guard infoCenter.playbackState != .stopped || infoCenter.nowPlayingInfo != nil else { return }
            infoCenter.nowPlayingInfo = nil
            infoCenter.playbackState = .stopped
            return
        }
        if current?.item != item { load(item) }
        let next = snapshot(of: item)
        if published.map({ !$0.sameShown(as: next) }) ?? true { publish(next) }
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
        !player.playWhenReady || player.state == .idle || player.state == .ended || player.suppression != .none
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
            position: player.position
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

    // media3 `SEEK_IN_CURRENT_MEDIA_ITEM`: off before the item opens and for a live or unseekable item.
    private var isSeekable: Bool { player.duration != nil }

    private var availableCommands: Set<RemoteCommand> {
        var commands: Set<RemoteCommand> = [.play, .pause, .togglePlayPause]
        switch skipMode {
        case .tracks:
            if player.hasNext { commands.insert(.nextTrack) }
            // media3 COMMAND_SEEK_TO_PREVIOUS, which restarts an item with no previous; a live one cannot.
            if player.hasPrevious || (player.currentItem != nil && !player.isLive) { commands.insert(.previousTrack) }
        case .intervals:
            if isSeekable { commands.formUnion([.skipForward, .skipBackward]) }
        }
        if isSeekable { commands.insert(.changePlaybackPosition) }
        if !supportedRates.isEmpty { commands.insert(.changePlaybackRate) }
        return commands
    }

    private func applyCommands() {
        let available = availableCommands
        for command in RemoteCommand.allCases {
            let enable = available.contains(command)
            guard enabledCommands.map({ $0.contains(command) != enable }) ?? true else { continue }
            commandCenter.setHandler(for: command, enable ? { [weak self] in self?.handle(command, $0) ?? .commandFailed } : nil)
        }
        enabledCommands = available
    }

    private func applySkipIntervals() {
        guard case let .intervals(forward, backward) = skipMode else { return }
        commandCenter.setSkipIntervals((forward, backward))
    }

    private func handle(_ command: RemoteCommand, _ event: RemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard player.currentItem != nil else { return .noActionableNowPlayingItem }
        switch (command, event) {
        case (.play, _): player.play()
        case (.pause, _): player.pause()
        // media3's `playIfSuppressed` default: a suppressed player shows play, so toggle plays.
        case (.togglePlayPause, _): showsPlay ? player.play() : player.pause()
        case (.nextTrack, _): player.skipToNext()
        // No 3 s threshold (ADR-0019): a previous item is always where it goes.
        case (.previousTrack, _): player.hasPrevious ? player.skipToPrevious() : player.seek(to: 0)
        case let (.skipForward, .interval(seconds)): player.seek(by: seconds)
        case let (.skipBackward, .interval(seconds)): player.seek(by: -seconds)
        case let (.changePlaybackPosition, .position(seconds)): player.seek(to: seconds)
        case let (.changePlaybackRate, .rate(rate)): player.rate = rate
        default: return .commandFailed
        }
        return .success
    }
}
