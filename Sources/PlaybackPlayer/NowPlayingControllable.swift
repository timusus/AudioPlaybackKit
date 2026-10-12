import Foundation

/// media3 `Player.Commands`: what a controller may ask of a player right now. A command left out is
/// greyed out on the lock screen, and a press of it that races the change is refused.
public struct PlayerCommands: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    /// `COMMAND_PLAY_PAUSE`.
    public static let playPause = PlayerCommands(rawValue: 1 << 0)
    /// `COMMAND_SEEK_TO_NEXT`: the next button.
    public static let seekToNext = PlayerCommands(rawValue: 1 << 1)
    /// `COMMAND_SEEK_TO_PREVIOUS`: the previous button, which restarts an item with nothing before it.
    public static let seekToPrevious = PlayerCommands(rawValue: 1 << 2)
    /// `COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM`: the scrubber.
    public static let seekInCurrentItem = PlayerCommands(rawValue: 1 << 3)
    /// `COMMAND_SEEK_FORWARD`: the skip-forward button, shown with `skipIntervals`.
    public static let seekForward = PlayerCommands(rawValue: 1 << 4)
    /// `COMMAND_SEEK_BACK`: the skip-back button, shown with `skipIntervals`.
    public static let seekBack = PlayerCommands(rawValue: 1 << 5)
    /// `COMMAND_SET_SPEED_AND_PITCH`.
    public static let setRate = PlayerCommands(rawValue: 1 << 6)
}

/// The seconds the skip buttons move by, drawn in their glyphs.
public struct SkipIntervals: Hashable, Sendable {
    public var forward: TimeInterval
    public var backward: TimeInterval

    public init(forward: TimeInterval, backward: TimeInterval) {
        self.forward = forward
        self.backward = backward
    }
}

/// What a Now Playing session shows and drives: a `Player`, or an app's wrapper that puts its own
/// policy between the system's remote commands and the player, as media3's `ForwardingPlayer`.
///
/// The session reads these under Observation and re-reads them whenever one changes, so a wrapper's
/// own state (what it vetoes, its intervals) must be `@Observable` or derived from the player's.
@MainActor
public protocol NowPlayingControllable<Item>: AnyObject {
    associatedtype Item: Hashable & Sendable

    var currentItem: Item? { get }
    var playWhenReady: Bool { get }
    var state: PlaybackState { get }
    var suppression: PlaybackSuppression { get }
    var isPlaying: Bool { get }
    /// Seconds of the current item's media time, as heard.
    var position: TimeInterval { get }
    /// Moves on every jump of `position`, as `Player.discontinuityCount`.
    var discontinuityCount: Int { get }
    /// Nil until the item has opened, and for a live stream.
    var duration: TimeInterval? { get }
    var isLive: Bool { get }
    var rate: Double { get set }

    var availableCommands: PlayerCommands { get }
    /// Non-nil puts skip-forward and skip-back on the lock screen in place of next and previous, for
    /// spoken word. Re-read on every item change, so it may differ per item.
    var skipIntervals: SkipIntervals? { get }

    func play()
    func pause()
    /// The next button.
    func seekToNext()
    /// The previous button: the previous item, or the start of this one with nothing before it.
    func seekToPrevious()
    func seek(to position: TimeInterval)
    func seek(by delta: TimeInterval)
}

/// A wrapper that forwards every requirement to `player`, so it declares only what its policy
/// changes. Its own declaration of a requirement replaces the forwarding one.
@MainActor
public protocol ForwardingNowPlayingControllable: NowPlayingControllable {
    var player: Player<Item> { get }
}

extension ForwardingNowPlayingControllable {
    public var currentItem: Item? { player.currentItem }
    public var playWhenReady: Bool { player.playWhenReady }
    public var state: PlaybackState { player.state }
    public var suppression: PlaybackSuppression { player.suppression }
    public var isPlaying: Bool { player.isPlaying }
    public var position: TimeInterval { player.position }
    public var discontinuityCount: Int { player.discontinuityCount }
    public var duration: TimeInterval? { player.duration }
    public var isLive: Bool { player.isLive }
    public var rate: Double {
        get { player.rate }
        set { player.rate = newValue }
    }
    public var availableCommands: PlayerCommands { player.availableCommands }
    public var skipIntervals: SkipIntervals? { player.skipIntervals }
    public func play() { player.play() }
    public func pause() { player.pause() }
    public func seekToNext() { player.seekToNext() }
    public func seekToPrevious() { player.seekToPrevious() }
    public func seek(to position: TimeInterval) { player.seek(to: position) }
    public func seek(by delta: TimeInterval) { player.seek(by: delta) }
}

extension Player: NowPlayingControllable {
    /// media3 `ExoPlayerImpl`'s available commands: next while there is a next item, previous on any
    /// item but a live one with nothing before it, seeking once the item is known to be seekable.
    public var availableCommands: PlayerCommands {
        var commands: PlayerCommands = [.playPause, .setRate]
        if hasNext { commands.insert(.seekToNext) }
        if hasPrevious || (currentItem != nil && !isLive) { commands.insert(.seekToPrevious) }
        if duration != nil { commands.formUnion([.seekInCurrentItem, .seekForward, .seekBack]) }
        return commands
    }

    /// Next and previous on the lock screen; a wrapper supplies intervals for spoken word.
    public var skipIntervals: SkipIntervals? { nil }

    /// `skipToNext`, as media3's `seekToNext` is `seekToNextMediaItem` for an item that is not live.
    public func seekToNext() { skipToNext() }

    /// media3 `seekToPrevious` without its 3 s threshold (ADR-0019): a previous item is always where
    /// it goes, and with none the item restarts.
    public func seekToPrevious() {
        hasPrevious ? skipToPrevious() : seek(to: 0)
    }
}
