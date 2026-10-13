import Foundation
import PlaybackDecode
import PlaybackRender

/// Makes the PCM source for an item when the player is about to decode it. Called on the main
/// actor and must not block: `FFmpegItemSource` opens lazily, so construct it and return.
public typealias ItemSourceFactory<Item> = @MainActor (Item) throws -> any ItemSource

/// media3 `Player.State`: `.idle` has nothing prepared or stopped on an error; `.buffering` is
/// waiting for audio (a load or seek not yet decoded, or decode behind the clock) whatever
/// `playWhenReady` is; `.ready` can play at once; `.ended` is the end of the last item.
public enum PlaybackState: Sendable {
    case idle, buffering, ready, ended
}

/// media3 `Player.RepeatMode`. Only the advance at the end of an item follows `.one`; `skipToNext`
/// and `skipToPrevious` treat it as `.off`.
public enum RepeatMode: Sendable {
    case off, all, one
}

/// Why audio is not heard although `playWhenReady` is true and the state is `.ready`.
public enum PlaybackSuppression: Sendable {
    case none
    /// An `AVAudioSession` interruption began; cleared when it ends (media3 `TRANSIENT_AUDIO_FOCUS_LOSS`).
    case interruption
}

/// Why playback stopped on its own; `kind` names the layer that failed.
public struct PlaybackError: Error, Sendable {
    public enum Kind: Sendable {
        case source, output, session
    }

    public var kind: Kind
    public var underlying: any Error

    /// What a caller acts on: retry a network or HTTP failure, skip an unsupported or malformed
    /// item. An error the library did not raise (an app's factory, the output, the session) is `.internal`.
    public var category: PlaybackErrorCategory {
        switch underlying {
        case let error as StreamDecoderError: error.category
        case let error as StreamByteReaderError: error.category
        default: .internal
        }
    }
}

public enum TransitionReason: Sendable {
    /// The previous item ended.
    case auto
    /// `skipToNext`, `skipToPrevious`, `seek(to:itemAt:)` or an edit that removed the current item.
    case seek
    /// Repeat one restarted the item.
    case `repeat`
}

public enum PlayWhenReadyChangeReason: Sendable {
    case routeLost, interruptionEnded, endOfItem
}

/// Discrete things the state cannot carry: each is sent once, in order, after the state that caused
/// it has been written.
public enum PlayerEvent<Item: Hashable & Sendable>: Sendable {
    /// `currentIndex` moved; `to` is nil when the list emptied.
    case itemTransition(from: Int?, to: Int?, reason: TransitionReason)
    /// The item at `index` failed, and the player is `.idle` on it with `error` set; there is no
    /// automatic skip. A next item that failed while the current played is reported once playback
    /// reaches it, after its `itemTransition`; removed or replaced before then, it is never reported.
    case itemFailed(index: Int, error: PlaybackError)
    /// The seek's audio reached the speaker; `position` is where it landed.
    case seekLanded(index: Int, position: TimeInterval)
    /// media3 `DISCONTINUITY_REASON_SEEK_ADJUSTMENT`: a seek went to `position` instead of `requested`.
    /// Sent at the call for a clamp to the item or a refusal by an unseekable item (which stays
    /// where it is), and after `seekLanded` when the source lands elsewhere. A load at a start
    /// position is checked the same way, with no `seekLanded`.
    case seekAdjusted(index: Int, requested: TimeInterval, position: TimeInterval)
    /// A renderer failure or media-services reset was recovered; playback is paused at the same position.
    case recoveredPaused
    /// `playWhenReady` changed by the player, not the app.
    case playWhenReadyChanged(Bool, reason: PlayWhenReadyChangeReason)
    /// media3 `onRenderedFirstFrame` for audio: the first `position` that moved while playing after a
    /// load, seek or item transition, so time to first audio counts from the call. Not after a resume.
    case firstAudioRendered(index: Int, position: TimeInterval)
    /// An underrun (media3 `onAudioUnderrun`): `.buffering` after the first audio, while
    /// `playWhenReady` and not suppressed. The wait after a load or seek is `firstAudioRendered`'s.
    case bufferingStarted(index: Int, position: TimeInterval)
    /// Ends the last `bufferingStarted`: audio resumed, or a pause, seek, load, stop or failure
    /// stopped the wait.
    case bufferingEnded
}
