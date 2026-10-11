import Foundation
import MediaPlayer

/// The remote commands a session answers.
enum RemoteCommand: CaseIterable {
    case play, pause, togglePlayPause, nextTrack, previousTrack, skipForward, skipBackward
    case changePlaybackPosition, changePlaybackRate
}

/// A command's payload, unwrapped from its `MPRemoteCommandEvent` subclass.
enum RemoteCommandEvent: Equatable {
    case plain
    case position(TimeInterval)
    case interval(TimeInterval)
    case rate(Double)
}

/// `MPRemoteCommandCenter` behind a seam: its events cannot be constructed, so tests call handlers.
@MainActor
protocol RemoteCommandCenter: AnyObject {
    /// Enables `command` with `handler`, replacing any earlier one; nil disables it.
    func setHandler(for command: RemoteCommand, _ handler: ((RemoteCommandEvent) -> MPRemoteCommandHandlerStatus)?)
    /// The intervals drawn in the skip glyphs.
    func setSkipIntervals(forward: TimeInterval, backward: TimeInterval)
    func setSupportedRates(_ rates: [Double])
}

/// `MPNowPlayingInfoCenter` behind a seam.
@MainActor
protocol NowPlayingInfoCenter: AnyObject {
    var nowPlayingInfo: [String: Any]? { get set }
    var playbackState: MPNowPlayingPlaybackState { get set }
}

extension MPNowPlayingInfoCenter: NowPlayingInfoCenter {}

/// The shared command centre: one target per command, removed before a replacement is added.
@MainActor
final class SystemRemoteCommandCenter: RemoteCommandCenter {
    private let center = MPRemoteCommandCenter.shared()
    private var targets: [RemoteCommand: Any] = [:]

    func setHandler(for command: RemoteCommand, _ handler: ((RemoteCommandEvent) -> MPRemoteCommandHandlerStatus)?) {
        let remote = self.command(command)
        if let target = targets.removeValue(forKey: command) {
            remote.removeTarget(target)
        }
        guard let handler else {
            remote.isEnabled = false
            return
        }
        remote.isEnabled = true
        targets[command] = remote.addTarget { event in
            // The system calls command targets on the main thread.
            MainActor.assumeIsolated { handler(Self.payload(of: event)) }
        }
    }

    func setSkipIntervals(forward: TimeInterval, backward: TimeInterval) {
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: forward)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: backward)]
    }

    func setSupportedRates(_ rates: [Double]) {
        center.changePlaybackRateCommand.supportedPlaybackRates = rates.map { NSNumber(value: $0) }
    }

    private func command(_ command: RemoteCommand) -> MPRemoteCommand {
        switch command {
        case .play: center.playCommand
        case .pause: center.pauseCommand
        case .togglePlayPause: center.togglePlayPauseCommand
        case .nextTrack: center.nextTrackCommand
        case .previousTrack: center.previousTrackCommand
        case .skipForward: center.skipForwardCommand
        case .skipBackward: center.skipBackwardCommand
        case .changePlaybackPosition: center.changePlaybackPositionCommand
        case .changePlaybackRate: center.changePlaybackRateCommand
        }
    }

    private nonisolated static func payload(of event: MPRemoteCommandEvent) -> RemoteCommandEvent {
        if let event = event as? MPChangePlaybackPositionCommandEvent { return .position(event.positionTime) }
        if let event = event as? MPSkipIntervalCommandEvent { return .interval(event.interval) }
        if let event = event as? MPChangePlaybackRateCommandEvent { return .rate(Double(event.playbackRate)) }
        return .plain
    }
}
