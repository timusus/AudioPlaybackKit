#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import Foundation
import MediaPlayer
import PlaybackPlayer
import PlaybackPlayerTestSupport
import PlaybackRender
import PlaybackRenderTestSupport
@testable import PlaybackNowPlaying

/// Records every write; `info` reads one key of what was written last.
@MainActor
final class FakeInfoCenter: NowPlayingInfoCenter {
    var nowPlayingInfo: [String: Any]? {
        didSet { writes += 1 }
    }
    var playbackState: MPNowPlayingPlaybackState = .unknown
    private(set) var writes = 0

    subscript<T>(_ key: String) -> T? { nowPlayingInfo?[key] as? T }
}

/// Keeps each command's handler, so a command is enabled exactly while it has one.
@MainActor
final class FakeCommandCenter: RemoteCommandCenter {
    private(set) var handlers: [RemoteCommand: (RemoteCommandEvent) -> MPRemoteCommandHandlerStatus] = [:]
    private(set) var intervals: (forward: TimeInterval, backward: TimeInterval)?
    private(set) var rates: [Double]?

    var enabled: Set<RemoteCommand> { Set(handlers.keys) }

    func setHandler(for command: RemoteCommand, _ handler: ((RemoteCommandEvent) -> MPRemoteCommandHandlerStatus)?) {
        handlers[command] = handler
    }

    func setSkipIntervals(_ intervals: (forward: TimeInterval, backward: TimeInterval)?) {
        self.intervals = intervals
    }

    func setSupportedRates(_ rates: [Double]) {
        self.rates = rates
    }

    /// What the handler answered, or nil for a disabled command.
    @discardableResult
    func fire(_ command: RemoteCommand, _ event: RemoteCommandEvent = .plain) -> MPRemoteCommandHandlerStatus? {
        handlers[command]?(event)
    }
}

/// A session over a `PlayerTestRig` of ten-second string items at 8 Hz.
@MainActor
final class NowPlayingRig {
    static let format = PCMFormat(sampleRate: 8, channelCount: 1)

    let base: PlayerTestRig<String>
    let info = FakeInfoCenter()
    let commands = FakeCommandCenter()
    private(set) var session: NowPlayingSession<String>!
    /// Artwork loads for these items wait for `deliverArtwork`.
    var heldArtwork: Set<String> = []
    private var artworkWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var artworks: [String: MPMediaItemArtwork] = [:]

    var player: Player<String> { base.player }

    init(skipMode: NowPlayingSession<String>.SkipMode = .tracks, supportedRates: [Double] = [], live: Set<String> = []) {
        base = PlayerTestRig { item in
            let source = FakeItemSource(format: Self.format, frames: 80, chunkFrames: 2)
            if live.contains(item) { source.duration = nil }
            return source
        }
        session = NowPlayingSession(
            player: base.player,
            skipMode: skipMode,
            supportedRates: supportedRates,
            metadata: { NowPlayingMetadata(title: $0.uppercased(), artist: "Artist \($0)", album: "Album", duration: 99) },
            artwork: { [weak self] in await self?.loadArtwork($0) },
            infoCenter: info,
            commandCenter: commands
        )
    }

    /// Runs the player for `seconds` of output, then lets the session catch up.
    func run(for seconds: TimeInterval) async {
        base.run(for: seconds)
        await settle()
    }

    /// Delivers the transport calls made so far, then lets the session read the result. The transport
    /// runs on its own queue, so a session reading before this would race it.
    func settle() async {
        base.settle()
        await session.pendingRefresh?.value
    }

    /// Resumes the latest held load of `item`, so loads can finish newest first.
    func deliverArtwork(for item: String) {
        artworkWaiters[item]?.popLast()?.resume()
    }

    private func loadArtwork(_ item: String) async -> MPMediaItemArtwork? {
        if heldArtwork.contains(item) {
            await withCheckedContinuation { artworkWaiters[item, default: []].append($0) }
        }
        let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: 1, height: 1)) { _ in Self.image() }
        artworks[item] = artwork
        return artwork
    }

    #if canImport(UIKit)
    private nonisolated static func image() -> UIImage { UIImage() }
    #else
    private nonisolated static func image() -> NSImage { NSImage() }
    #endif
}
