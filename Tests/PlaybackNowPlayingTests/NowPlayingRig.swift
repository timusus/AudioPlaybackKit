#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import Foundation
import MediaPlayer
import Observation
import PlaybackPlayer
import PlaybackPlayerTestSupport
import PlaybackRender
import PlaybackNowPlayingTestSupport
import PlaybackRenderTestSupport
@testable import PlaybackNowPlaying

/// An app's policy over the player, as Shuttle2's `SessionPlayer`: everything else forwards.
@MainActor @Observable
final class PolicyPlayer: ForwardingNowPlayingControllable {
    typealias Item = String

    @ObservationIgnored let player: Player<String>
    var removed: PlayerCommands = []
    /// For every item without its own in `itemIntervals`; nil for next and previous.
    var intervals: SkipIntervals?
    var itemIntervals: [String: SkipIntervals] = [:]
    var vetoesNext = false
    private(set) var vetoedNexts = 0
    /// Every rate set through the wrapper, as an app persisting its speed.
    private(set) var savedRates: [Double] = []

    init(_ player: Player<String>, intervals: SkipIntervals? = nil) {
        self.player = player
        self.intervals = intervals
    }

    var availableCommands: PlayerCommands { player.availableCommands.subtracting(removed) }

    var skipIntervals: SkipIntervals? { player.currentItem.flatMap { itemIntervals[$0] } ?? intervals }

    var rate: Double {
        get { player.rate }
        set {
            savedRates.append(newValue)
            player.rate = newValue
        }
    }

    func seekToNext() {
        guard !vetoesNext else { return vetoedNexts += 1 }
        player.seekToNext()
    }
}

/// A session over a `PlayerTestRig` of ten-second string items at 8 Hz.
@MainActor
final class NowPlayingRig {
    static let format = PCMFormat(sampleRate: 8, channelCount: 1)

    let base: PlayerTestRig<String>
    let info = FakeNowPlayingInfoCenter()
    let commands = FakeRemoteCommandCenter()
    private(set) var session: NowPlayingSession<String>!
    /// Artwork loads for these items wait for `deliverArtwork`.
    var heldArtwork: Set<String> = []
    private var artworkWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var artworks: [String: MPMediaItemArtwork] = [:]
    /// The session's clock, moved with the output's by `run`; a test moves it alone for output that starts late.
    var wall: TimeInterval = 0

    var player: Player<String> { base.player }

    /// `wrap` puts an app's wrapper between the session and the player.
    init(
        supportedRates: [Double] = [],
        live: Set<String> = [],
        unknownLength: Set<String> = [],
        wrap: (Player<String>) -> any NowPlayingControllable<String> = { $0 }
    ) {
        let factory = FakeItemFactory<String>(format: Self.format)
        (factory.live, factory.unknownLength) = (live, unknownLength)
        base = PlayerTestRig { try factory.make($0) }
        controlled = wrap(base.player)
        self.supportedRates = supportedRates
        session = makeSession()
    }

    private let controlled: any NowPlayingControllable<String>
    private let supportedRates: [Double]

    private func makeSession() -> NowPlayingSession<String> {
        NowPlayingSession(
            player: controlled,
            supportedRates: supportedRates,
            metadata: { NowPlayingMetadata(title: $0.uppercased(), artist: "Artist \($0)", album: "Album", duration: 99) },
            artwork: { [weak self] in await self?.loadArtwork($0) },
            infoCenter: info,
            commandCenter: commands,
            now: { [weak self] in self?.wall ?? 0 }
        )
    }

    /// Replaces the session with a new one over the same centres, as `self.session = NowPlayingSession(...)`
    /// in an app, and returns the old one.
    @discardableResult
    func replaceSession() -> NowPlayingSession<String> {
        let old = session!
        session = makeSession()
        return old
    }

    /// Drops the only reference to the session; `settle` and `run` need it afterwards. The release hops
    /// to the main actor, and a task queued after it runs after it.
    func dropSession() async {
        session = nil
        await Task { @MainActor in }.value
    }

    /// Runs the player for `seconds` of output, then lets the session catch up.
    func run(for seconds: TimeInterval) async {
        base.run(for: seconds)
        wall += Double(Int(seconds * 4)) / 4
        await settle()
    }

    /// Delivers the transport calls made so far, then lets the session read the result. The transport
    /// runs on its own queue, so a session reading before this would race it.
    func settle() async {
        base.settle()
        await session.settle()
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
