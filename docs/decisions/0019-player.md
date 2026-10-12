# ADR-0019: A player layer over Transport

Status: Accepted (2026-10-11)
Date: 2026-10-11

## Context

[ADR-0018](0018-render-layer.md) ends the package at `Transport`: current and next item, play, pause,
seek, rate, volume, processors, events, one recovery path. Everything above it is written twice today,
once per app, and the two copies disagree:

| Concern | Shuttle Podcasts (`mobile/ios`) | Shuttle2 (`ios`) |
|---|---|---|
| Engine and state machine | `AVAudioEnginePlaybackController` (2,674 lines), `PlaybackControlling`, `PlaybackControllerState` (idle, loading, playing, buffering, paused, ended, error) | `MusicPlaybackController` and six extensions (`Engine/`), `State` (idle, loading, playing, paused, ended), `EngineAudioPlayer`, `AudioEngine.swift` |
| Audio session | category set in `ShuttlePodcastsApp.swift`, interruptions and `oldDeviceUnavailable` in the controller, `HeadphoneObserver`; media-services reset unhandled; `CarPlaySceneDelegate.configureAudioSession` sets options the app's own comment says throw | `AudioSessionController`: `.playback`/`.longFormAudio`, lazy off-main activation, `pausesOnRouteChange` by personal output kind, resume only with `shouldResume` and no user action in between, media-services reset rebuilds the engine |
| Position and duration | `TimeInterval` published from a 0.5 s timer, duration from the decoder or feed | `(uid, ms)` from a 100 ms timer, `durationMs` from the container or the library |
| Item advance and failures | Kotlin `QueueAutoAdvanceManager` on `Ended`; no per-item error policy, playback stops | Kotlin `IosEngineFeeder.feedNext` pre-arms the next, `IosEngineEvents.onCurrentFailed` skips up to 15 failures |
| Now Playing and remote commands | `NowPlayingInfoManager`, `RemoteCommandHandler` (rate from `isPlayIntended`) | `NowPlayingController` (writes elapsed only on a state change or a jump), `PlaybackSystemCoordinator` |

Both apps keep their queue, position saving, sleep timer and speed policy in shared Kotlin
(`IosPlayerController.kt`, `QueueModel.kt` with `ShuffleOrder.kt`, `SleepTimerManager.kt`,
`ObserveAndStorePlaybackPosition.kt`), and reach the engine through one bridge, `IosAudioPlayer`.
Neither app uses `PlaybackRender` yet. The owner has decided the package should grow a player both
apps adopt directly.

The references are media3's `Player` (`playWhenReady` and `playbackState` kept apart, a
`PlaybackSuppressionReason`, a `MediaItem` list with a current index, `Player.Listener`,
`setPauseAtEndOfMediaItems`, `handleAudioBecomingNoisy`, `MediaSession` as a separate module) and
AVFoundation's `AVPlayer` (`timeControlStatus` with `reasonForWaitingToPlay`, periodic time observers,
`AVQueuePlayer`, `actionAtItemEnd`). From AVPlayer we keep the idea that waiting has a reason and that
the position is pushed to the UI on a cadence; we reject KVO on `AVPlayerItem.status`, the lack of a
`playWhenReady` (an interruption leaves `rate` at 0 and nothing says why), `CMTime`, and
`AVQueuePlayer`'s forward-only queue that cannot go back. From media3 we keep the state model, the item
list, the one listener, pause-at-end and the separate session module; we reject a `Timeline` of windows
and periods (no ads, no live DASH), the `ForwardingPlayer` indirection (the apps compose a `Player`,
they do not subclass it), audio focus (iOS has the session instead) and `ShuffleOrder` inside the
player, for the reason given under queue features.

## Decision

We will add a `PlaybackPlayer` product that depends on `PlaybackRender` only and drives `Transport`
through its public API, and a `PlaybackNowPlaying` product that depends on `PlaybackPlayer` and
`MediaPlayer`. Each app replaces its engine, state machine, session handling and Now Playing code with
them, and keeps its queue model, persistence, sleep timer, speed policy, effects and UI.

### Layering and products

| Product | Depends on | Owns | Does not know |
|---|---|---|---|
| `PlaybackPlayer` | `PlaybackRender` | `Player`: the item list and current index, `playWhenReady` and the state, position and duration in seconds, seek across items, auto-advance and pre-arm, repeat, pause at end, per-item errors, the `AVAudioSession` behind one seam | PCM, frames, timestamps, metadata, UI |
| `PlaybackNowPlaying` | `PlaybackPlayer`, `MediaPlayer` | `NowPlayingSession`: `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` driven from a `Player` | what an item is; the app supplies the metadata |
| `PlaybackPlayerTestSupport` | `PlaybackPlayer`, `PlaybackRenderTestSupport` (#116) | `FakeAudioSession`, `FakeItemFactory`, a `Player` initialiser taking them and the fake output | |

`Player` reaches `Transport` only through `setCurrent`, `setNext`, `clearNext`, `play`, `pause`,
`seek`, `setRate`, `setVolume`, `setProcessors`, `stop` and `TransportEvent`. It never imports with
`@testable`, so anything it needs from the render layer is a public change to `Transport`, listed under
Implementation. These stay public, because an app still composes them: `Transport`, `TransportEvent`,
`TransportStatus`, `ItemSource`, `FFmpegItemSource`, `AudioProcessor`, `ProcessorOutput`,
`DroppedFrames`, `PCMFormat`. An app that wants no player (a test rig, a macOS tool) keeps driving
`Transport`.

Now Playing is a separate product as media3's `MediaSession` is: it links `MediaPlayer`, an app may have
CarPlay templates or widgets that render the same state another way (Shuttle2's `NowPlayingWidgetPublisher`,
both apps' `CPNowPlayingTemplate` custom buttons), and its tests need no renderer at all.

The `AVAudioSession` policy lives in `PlaybackPlayer`, behind the internal `AudioSessionControlling`
seam. The app's one override is an `AudioSessionConfiguration` (category, mode, route-sharing policy,
options) passed to `Player.init`; `SystemAudioSession` applies it. Neither app needs a conformer of its
own, so the seam and `SystemAudioSession` stay internal and only tests replace them. The rules that act on session events (when to pause, when to resume, when to reactivate)
are the player's and not configurable; both apps' rules are the same once the gaps in the Podcasts copy
are filled, and Shuttle2's `AudioSessionController` rules are the ones the player implements. The
widget publisher (`NowPlayingWidgetPublisher`) stays in Shuttle2: it is one of those other renderings.

Nothing about podcasts, music libraries, ads, chapters or UI goes in. Chapters are a seek the app
computes; Smart Skip is seeks, a `setVolume` duck and a chime the app plays; the sleep timer is the
app's timer over `pause()` and `pauseAtEndOfItem`.

### The public API

```swift
import PlaybackPlayer

/// Makes the PCM source for an item when the player is about to decode it. Called on the main
/// actor and must not block: `FFmpegItemSource` opens lazily, so construct it and return.
public typealias ItemSourceFactory<Item> = @MainActor (Item) throws -> any ItemSource

/// media3 `Player.State`: `.idle` has nothing prepared or stopped on an error; `.buffering` is
/// `playWhenReady` with decode behind the clock, or an item opening; `.ready` can play at once;
/// `.ended` is the end of the last item.
public enum PlaybackState: Sendable { case idle, buffering, ready, ended }

/// Why audio is not heard although `playWhenReady` is true and the state is `.ready`.
public enum PlaybackSuppression: Sendable {
    case none
    /// An `AVAudioSession` interruption began; cleared when it ends (media3 `TRANSIENT_AUDIO_FOCUS_LOSS`).
    case interruption
}

/// media3 `Player.RepeatMode`. Only the advance at the end of an item follows `.one`; `skipToNext`
/// and `skipToPrevious` treat it as `.off`.
public enum RepeatMode: Sendable { case off, all, one }

public struct PlaybackError: Error, Sendable {
    public enum Kind: Sendable { case source, output, session }
    public var kind: Kind
    public var underlying: any Error
}

/// Discrete things the state cannot carry: each is sent once, in order.
public enum PlayerEvent<Item: Hashable & Sendable>: Sendable {
    /// `currentIndex` moved: `.auto` when the previous item ended, `.seek` on `skipToNext`, `seek(to:itemAt:)`
    /// or an edit that removed the current item, `.repeat` when the end of an item restarted it.
    case itemTransition(from: Int?, to: Int?, reason: TransitionReason)
    /// The item at `index` failed, and the player is `.idle` on it with `error` set. A next item that
    /// failed while the current played is reported once playback reaches it, after its `itemTransition`.
    case itemFailed(index: Int, error: PlaybackError)
    /// The seek's audio reached the speaker; `position` is where it landed.
    case seekLanded(index: Int, position: TimeInterval)
    /// A renderer failure or media-services reset was recovered; playback is paused at the same position.
    case recoveredPaused
    /// `playWhenReady` changed by the player, not the app: a route went (`.routeLost`), an interruption
    /// ended without `shouldResume` (`.interruptionEnded`), the end was reached (`.endOfItem`).
    case playWhenReadyChanged(Bool, reason: PlayWhenReadyChangeReason)
}

@MainActor @Observable
public final class Player<Item: Hashable & Sendable> {
    public init(
        makeSource: @escaping ItemSourceFactory<Item>,
        audioSession: AudioSessionConfiguration = .longFormAudio,
        timePitchAlgorithm: AVAudioTimePitchAlgorithm = .timeDomain
    )

    // Items. The list is the app's; the player keeps a private entry id per position so an item may
    // appear twice (repeat one, a track queued twice) and `Transport` is driven by the entry id.
    public private(set) var items: [Item]
    public private(set) var currentIndex: Int?
    public var currentItem: Item? { currentIndex.map { items[$0] } }
    public func setItems(_ items: [Item], startIndex: Int = 0, startPosition: TimeInterval = 0)
    /// Keeps playing if `newItems[currentIndex]` is the item playing now; otherwise behaves as `setItems`.
    public func replaceItems(_ newItems: [Item], currentIndex: Int)
    public func insert(_ items: [Item], at index: Int)
    public func move(from: Int, to: Int)
    public func remove(at index: Int)
    public func removeAll()

    // Transport.
    public var playWhenReady: Bool { get set }      // play() and pause() are sugar
    public func play(); public func pause()
    public private(set) var state: PlaybackState
    public private(set) var suppression: PlaybackSuppression
    public var isPlaying: Bool { state == .ready && playWhenReady && suppression == .none }
    public private(set) var error: PlaybackError?
    public func stop()                              // `.idle`, session deactivated, items kept
    public func skipToNext(); public func skipToPrevious()
    public var hasNext: Bool { get }; public var hasPrevious: Bool { get }

    // Position, in seconds of the current item's media time.
    public private(set) var position: TimeInterval   // what is heard; updated every 100 ms while it changes
    public private(set) var duration: TimeInterval?  // nil until probed, or for a live stream
    public private(set) var isLive: Bool
    public private(set) var discontinuityCount: Int  // changes on every jump of `position`, never on playback
    public func seek(to position: TimeInterval)
    public func seek(to position: TimeInterval, itemAt index: Int)
    public func seek(by delta: TimeInterval)         // clamps to 0...duration, never advances

    // Rate and volume.
    public var rate: Double { get set }              // 0.25...4, pitch kept; never 0
    public var volume: Float { get set }             // 0...1, applied at once; ramps are the app's timer
    public var repeatMode: RepeatMode { get set }
    public var pauseAtEndOfItem: Bool { get set }
    public func setProcessors(_ processors: [any AudioProcessor])

    public var events: AsyncStream<PlayerEvent<Item>> { get }
}
```

**Edits while playing.** Index arithmetic follows media3's `ExoPlayerImpl.addMediaItems`,
`moveMediaItems` and `removeMediaItems`: the current item keeps playing through any insert or move,
and `currentIndex` is renumbered. Removing the current item plays the item that takes its index from
position 0 (the next, or under `.all` the first); removing the last remaining item leaves `.idle` with
no current index. Removing the current item when it is the last leaves index 0 in `.ended` (under `.all`
it plays index 0), and under `.one` removing the current item always ends, as media3 does
(`removeMediaItem_withRepeatModeOne_endsPlaybackAndStopsLoading`). Adding to an ended list stays
`.ended` until a seek, as media3 does. `setItems` and `replaceItems` send no `itemTransition`. Any edit
that changes which item follows the current re-issues `setNext` (or `clearNext`), so the pre-armed next
is always the list's next. The transport keys each load and each arm afresh and the player resolves a
`.crossed` key to its entry, so a crossing into a next armed before an edit is reported at that entry's
new index. Once decode has reached the armed next the transport has joined into it, so it is still heard:
an insert after that point plays after it (media3 would drop the read-ahead), and a removed next is
replaced by a jump to the list's next as soon as the crossing arrives.

**State.** `playWhenReady` is the app's intent and only the app or a session event changes it.
`state` is what the transport reports: `TransportStatus.paused` or `.playing` with a current item is
`.ready`, `.buffering` is `.buffering`, `.ended` is `.ended`, and no item or a failed current item is
`.idle`. An interruption sets `suppression` and leaves `playWhenReady` alone, so a UI shows "paused by
a call" and the resume after `shouldResume` needs no app code. `.ended` is terminal for the list:
`play()` on `.ended` restarts the current item from 0, as media3 does from `STATE_ENDED`.

**Observation.** `@Observable` on the main actor is the primary mechanism: SwiftUI reads properties and
redraws on exactly the ones it read, Now Playing reads them from `withObservationTracking`, and nothing
needs Combine. One `AsyncStream` of `PlayerEvent` is kept for the facts that observation coalesces or
loses: a transition from item 3 to item 4 to item 5 within one run of the main loop, a failure, a seek
landing. Both exist because they answer different questions (what is true now, what happened), and
neither is a protocol with eleven optional methods. Events are delivered on the main actor after the
state that caused them has been written, so a handler reading `player.currentIndex` sees the new value.

**Position.** `TimeInterval`, not `CMTime`: both apps store and display seconds or milliseconds, the
decoder's sample-accurate seek takes seconds (`seek(toSeconds:)`), and `CMTime` buys a timescale we
never need because frames at the item's rate stay inside `Transport`. `position` is written when a
`TransportEvent.position` arrives, which is once a pump (100 ms) while it changes; a view that wants
2 Hz samples it. Within an item it never goes back except on a seek, so a position saver can take
deltas as listening time. `discontinuityCount` is media3's `onPositionDiscontinuity` as an observed
property: it changes on every seek, skip, load, transition and repeat, and never on a pump. It changes
with the call, as media3 masks the seek target in at once, not when the seek lands: the call has
already written the target to `position`, so a reader such as Now Playing gets the jump and the new
position together, and the landing plays on from there.

**Seek.** `seek(to:)` within the current item or an armed next calls `Transport.seek`; a seek to a
later or earlier item that the transport no longer holds is a `setCurrent` of that entry followed by
`setNext` of the one after it. The target is clamped to `0...duration` when the duration is known. A
live item ignores seeks (`isLive`). Stopped or failed, a seek only moves the index and position and the
state stays `.idle` until `play()`, as media3 waits for `prepare`. `position` shows the target at once;
transport events sent before the transport answers the call with `.sought` are held (media3's
`pendingOperationAcks`). Meanwhile `state` is `.buffering`, as media3 masks a seek or
`setMediaItems` as `STATE_BUFFERING`, so it never describes where playback was before the call (#145).
An applied call drops the held events and leaves the status `.buffering`, as a restart buffers and reports
only a change from there, so `state` again comes from the transport; a seek the transport ignored,
because a crossing passed its item, drops nothing, so that crossing still advances the index. The
first position after the answer sends `seekLanded`. `seek(by:)` adds to a
target not yet heard, so rapid presses add up. An `ItemSource.seek` that throws (a forward-only transcode) arrives
as `itemFailed` for that item; the app, which knows the stream can be re-resolved at an offset
(Shuttle2's `onSeekUnsupported`), replaces the item.

**Errors.** The `Transport` reports a source, processor or output failure with its item. If the item is
current, `error` is set, `state` is `.idle`, `playWhenReady` is kept and `play()` re-prepares the current
item from `position` (media3: `prepare()` after an error). If it is the armed next (the pre-arm opened
it early, or it failed while decoded ahead), the current item plays on, and the failure is held until
playback reaches it: then the player moves to that item, sends `itemTransition(.auto)`, stops `.idle`
with `error` set and sends `itemFailed`, as media3 reports a read-ahead error only after the transition
(`mediaPeriodMaybeThrowPrepareError_isNotThrownUntilPlaybackReachedFailingItem`). If the app removes or
replaces it first, it is never reported. There
is no automatic skip: Shuttle2 skips up to 15 failed tracks unless the track already played and
Podcasts stops, so the policy is the app's, in one `events` handler.

**Rate and volume.** `rate` is `Transport.setRate` and `volume` is `Transport.setVolume`; pause is
`playWhenReady`, never rate 0. Fades (the Podcasts sleep timer's 10 s ramp, the Smart Skip duck) are the
app writing `volume` from its own timer, as today.

**Threading.** `Player` is `@MainActor`: every call and every property is main-actor isolated, which is
where SwiftUI, `MPRemoteCommandCenter` handlers and both apps' Kotlin bridges already run. The item
factory runs on the main actor and must not block. `Transport` events arrive on its queue and are
forwarded through one `AsyncStream` consumed by a single task on the main actor, so order is kept. The
player never waits on the transport (whose `flush` blocks about 75 ms on its own queue), so no call takes
longer than a dispatch. `Item` is `Hashable & Sendable` because it crosses to the transport's queue as
the event key. `Player` itself is not `Sendable`; one exists per app.

### Usage

A Podcasts episode with a saved position and Smart Skip:

```swift
let player = Player<Episode>(
    makeSource: { episode in
        let source = GrowingFileByteSource(url: episode.enclosureURL, authHeaders: [:], store: .podcasts)
        skipScan.attach(to: source)                              // the GrowingFileListener tap stays
        return FFmpegItemSource(reader: source)
    },
    audioSession: .spokenAudio
)
player.setProcessors([silenceGate, voiceEnhance])
player.setItems([episode], startPosition: saved.position)          // seconds, from the Kotlin saver
player.play()
Task { for await event in player.events { if case .seekLanded = event { skipCoordinator.seekLanded() } } }
// Smart Skip: a cue's ad range is `player.seek(to: cue.end)`, the duck is a `player.volume` ramp.
```

A Shuttle2 album, gapless, the shuffled order coming from `QueueModel`:

```swift
let player = Player<PlaybackTrack>(makeSource: { track in
    GainedItemSource(FFmpegItemSource(reader: try track.makeReader()), gainDb: track.gainDb)
})
player.setProcessors([equalizer, limiter])
player.repeatMode = queue.repeatMode.player                        // Kotlin RepeatMode -> RepeatMode
player.setItems(queue.playOrder, startIndex: queue.currentIndex)   // shuffled by QueueModel.ShuffleOrder
player.play()
// On a queue edit from Kotlin:
player.replaceItems(queue.playOrder, currentIndex: queue.currentIndex)   // the current track keeps playing
```

A SwiftUI now-playing view:

```swift
struct NowPlayingBar: View {
    let player: Player<Episode>
    var body: some View {
        HStack {
            Button(player.playWhenReady ? "Pause" : "Play") { player.playWhenReady.toggle() }
            if player.state == .buffering { ProgressView() }
            if player.suppression == .interruption { Text("Paused by another app") }
            Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }),
                   in: 0...(player.duration ?? 1)).disabled(player.isLive)
        }
    }
}
```

### Queue features

| Feature | Whose | Why |
|---|---|---|
| Ordered list, current index, insert, move, remove, replace | player | Needed to pre-arm the right next item and to renumber on edits; media3 `Player` has them all |
| Repeat `.off`, `.all`, `.one` | player | The player must know what follows the last item to arm it gaplessly; `.one` is the same entry armed twice (`Transport` allows a repeated item) |
| Shuffle order | app | Both apps keep it in Kotlin: Shuttle2's `QueueModel` holds entries plus a `ShuffleOrder` of indices, with media3 `DefaultShuffleOrder` semantics (the current item first, an add goes to the end of the order, play-next after the current, a move moves within the order and never reshuffles). It is persisted and shared with Android. The player takes the list in play order and `replaceItems` keeps the current track playing when shuffle toggles. Putting a second `ShuffleOrder` in the player would be a second record of the same thing |
| Pause at end of item | player | `pauseAtEndOfItem`, media3 `setPauseAtEndOfMediaItems`: the player sends `clearNext`, and at `.ended` sets `playWhenReady` false, advances `currentIndex` and prepares the next item paused at 0 (media3 instead pauses at the end of the item and moves on at `play`; landing on the next lets the UI show what `play` starts). At the last item it ends. Set after the next was armed, the crossing pauses the next at 0. Shuttle2's `setPauseAtEnd` and `onPausedAtEnd` map onto it |
| Sleep timer | app | A countdown (`SleepTimerManager.kt`, `SleepTimer.kt`) that calls `pause()`, or sets `pauseAtEndOfItem` for "end of episode"; the Podcasts fade is a `volume` ramp. Policy and UI differ per app |
| Crossfade | out of scope | Neither app has it on iOS (Shuttle2's `crossfade_duration_ms` is Android-only). ADR-0018 places it in the render layer as a second `Transition`, not in the player; the player gains one property when that exists |
| Pre-arm and gapless handoff | player | As soon as a current item is set and the list has a next, `setNext(next)`; again on every edit that changes the next, `clearNext` when nothing follows or `pauseAtEndOfItem` is on. `Transport` decodes ahead, so the next opens early (Shuttle2's `PreopenLead` is deleted). `.crossed` advances `currentIndex` and sends `itemTransition(.auto)`; the item after the new current is armed then |

### Audio session

Rules, taken from Shuttle2's `AudioSessionController` and media3's `AudioFocusManager`:

- **Activation** is lazy: the first `play()` after init or `stop()` calls `setActive(true)` off the main
  thread, before `Transport.play()`; a throw refuses the play (`error.kind == .session`, `playWhenReady`
  stays true so the user's next tap retries). The category is set at init. `stop()`, the list
  emptying, and an item failure call `setActive(false, options: .notifyOthersOnDeactivation)`: failed
  is idle, as media3 abandons focus on idle, so a `play()` whose item fails to load never activates and
  an item failure clears `suppression`.
- **Interruption began**: the system has deactivated the session, so the next play activates again.
  If `playWhenReady` is true and an item is loaded without an error, `suppression = .interruption` and
  `Transport.pause()`; `playWhenReady` is untouched. Paused, stopped or failed, nothing is suppressed and
  nothing resumes, so the session is never activated with nothing to play and a stopped player gets no
  `playWhenReadyChanged`. The guard sits on the suppression rather than on activation, so a stopped
  player never shows "paused by another app" either. A `pause()` from the app during
  the interruption clears `suppression`, which is the memory of wanting to resume (Shuttle2's "no user
  action in between").
- **Interruption ended** while still suppressed: with `shouldResume`, `setActive(true)`, then
  `Transport.play()` and `suppression = .none`; if reactivation throws the player stays suppressed, with
  no error, and retries on the next `play()`. Without `shouldResume`: `suppression = .none` and
  `playWhenReady = false` with reason `.interruptionEnded`, so the UI shows paused. A `play()` during the
  interruption reactivates at once (media3's regular gain); if that throws it too stays suppressed.
- **Route change**: `oldDeviceUnavailable` pauses only when a personal output kind (headphones,
  Bluetooth, USB, line out, car, AirPlay) left the route and no output of that kind remains
  (`pausesOnRouteChange`); a Bluetooth profile switch plays on. The pause is `playWhenReady = false`
  with reason `.routeLost`, media3's `handleAudioBecomingNoisy`. It also clears the resume memory, so an
  unplug during a call never resumes onto the speaker. `newDeviceAvailable` does nothing: Podcasts'
  auto-play on headphones (`HeadphoneObserver`, `pref_auto_play_headphones`) is a preference and stays in
  the app, which observes the route itself.
- **Media-services reset**: the session seam reports it; the player sets the category again, marks the
  session inactive and clears `suppression`; the next `play()` activates again. On iOS
  `SampleBufferAudioOutput` observes the same notification, and the feeder rebuilds the output and
  restarts paused at the heard position (ADR-0018: one recovery layer), whichever of the two hears it
  first. That rebuild, like the one after a renderer failure, sends `TransportEvent.recovered`; on it the
  player, with an item loaded, sets `playWhenReady = false` without a `playWhenReadyChanged`, clears
  `suppression`, pauses the transport (covering a `play()` the transport took before the event arrived)
  and sends `recoveredPaused`. Both recoveries share this one path. `.recovered` is never held behind an
  unanswered seek: the feeder's pause outlives any restart. Shuttle2's `rebuildEngine` and
  `reloadEngine(positionMs:)` go; Podcasts gains handling it never had.
- **Pump while suppressed**: an app `seek` or `skipToNext` during an interruption is applied paused;
  the resume rule above decides whether audio starts.

### Testing

Every rule is driven without a device through four fakes: `FakeAudioOutput` and the manual clock
(#116), `FakeAudioSession` (records configure, activate and deactivate calls, can make activation
throw or wait, and
posts `interruptionBegan`, `interruptionEnded(shouldResume:)`, `routeChanged(reason:previous:current:)`
and `mediaServicesReset`), and `FakeItemFactory` (hands a `FakeItemSource` per item with a chosen
format, length and failure point, and records which items were asked for and when). `Player` gets an
internal initialiser taking a `Transport` built on the fake output, the session seam and the factory.
In this slice `FakeAudioSession` lives in the test target, since a separate module cannot see internal
symbols. For each app to test its own coordinator the same way, slice 5 (#123) widens
`AudioSessionControlling`, `AudioSessionEvent`, `AudioRouteChangeReason`, `AudioPortKind` and that
initialiser (and `drainTransportEvents`, which the rig needs to step deterministically) to
`@_spi(Testing) public`, and moves `FakeAudioSession` and a generic `PlayerTestRig<Item>` into
`PlaybackPlayerTestSupport`. `FakeItemFactory` followed in #144, generic over the app's item, so an
app scripts failures, early ends and stalls per item as the package's tests do. The product imports
`PlaybackPlayer` with `@_spi(Testing)`. Not `package` access: the apps' test targets are in other
packages, so a `package` symbol cannot reach them, nor appear in TestSupport's public API.
`@_spi(Testing)` is what `Transport.init(output:timer:executor:onEvent:)` already uses. Tests advance
the clock, fire the pump and `await` the main-actor state.

Cases each slice must have:

- **Core**: `setItems` arms current and next in the factory's call order; `state` follows
  `TransportStatus`; `playWhenReady` is unchanged by transport events; position in seconds matches the
  fake clock; `duration` arrives after open and is nil for a live source; `seek(to:)` within the item,
  to an armed next, to a later item (a `setCurrent`), and to an earlier item; `seek(by:)` clamps; rate
  and volume reach the output; `isPlaying` truth table over state, intent and suppression.
- **Edits**: insert before, at and after the current keeps playing and renumbers; move the current, move
  across it; remove a later item re-arms; remove the current plays its successor; remove the last leaves
  `.idle`; `replaceItems` with the same current item keeps the position; with another item restarts.
- **Advance**: `.crossed` advances the index and sends `itemTransition(.auto)`; the item after it is
  armed; `.all` wraps and `.one` re-arms the same entry; `.off` ends with `.ended`; `play()` on `.ended`
  restarts at 0; `pauseAtEndOfItem` lands paused at 0 of the next with `playWhenReady` false; a crossing
  into a next armed before an edit resolves by entry. Each in-scope `ExoPlayerTest` case is ported, and
  `docs/player-conformance-mapping.md` maps every one.
- **Errors**: a current item failing to open gives `.idle`, `error`, `itemFailed`, and `play()` retries
  from `position`; a next item failing to open or mid-decode keeps the current playing (no
  `Transport.pause`) and is reported after its `itemTransition` when playback reaches it, never if it was
  removed first.
- **Session**: the first `play()` activates once before `Transport.play()`; a throwing activation
  refuses with a `.session` error and leaves `playWhenReady` true; interruption began suppresses and
  pauses the transport; ended with `shouldResume` reactivates and plays; without it sets `playWhenReady`
  false with reason; an app `pause()` during the interruption prevents the resume; a reactivation that
  throws stays suppressed; `oldDeviceUnavailable` for headphones pauses with reason `.routeLost`; a
  Bluetooth profile switch does not; an unplug during an interruption cancels the resume; a
  media-services reset reconfigures the category, lands paused and sends `recoveredPaused`, twice in a
  row and during an interruption too, and so does a renderer failure the transport recovers, even
  held behind a seek; an interruption after `stop()` neither reactivates nor sends
  `playWhenReadyChanged`; `stop()` deactivates with `notifyOthersOnDeactivation`. Each
  in-scope `AudioFocusManagerTest` case is mapped in `docs/player-conformance-mapping.md`.
- **Now Playing**: the info centre gets title, duration, elapsed and rate on item change and state
  change and not on each position tick; a 15 s skip interval registers `skipForward` and not
  `nextTrack`, and the reverse; each remote command calls the player method; `changePlaybackRate`
  registers only with `supportedRates`. The session writes elapsed time when the player's
  `discontinuityCount` changes, so every seek is seen, however small and whether or not it buffers.
  Commands follow media3's availability: play and pause always, next while `hasNext`, skips and
  scrubbing once the duration is known (unseekable before it opens and when live). Previous is
  media3's `COMMAND_SEEK_TO_PREVIOUS`, which the lock-screen button is, not
  `SEEK_TO_PREVIOUS_MEDIA_ITEM`: enabled on any item but a live one with nothing before it, it goes to
  the previous item, or with none restarts the current one, without media3's 3 s threshold. Artwork is
  an async loader whose result is dropped once another load has started; `release()` ends a session
  and clears the rates and skip intervals it set.

### Migration impact

Both apps should migrate straight onto `Player`, not onto `Transport` first. Each reaches the engine
through one Kotlin bridge (`IosAudioPlayer`) and one Swift adapter (Podcasts `EngineAudioPlayerBridge`,
Shuttle2 `EngineAudioPlayer`), so the surface to rewrite is that adapter; moving it to `Transport` first
means writing the session, state-machine and advance code a second time only to delete it. The
`docs/migrating.md` order of work changes to: pin the tag, add `PlaybackPlayer`, build a `Player`
behind the flag in the adapter, port effects as processors, flip the flag, delete. The per-app tables
become:

| Shuttle Podcasts (`mobile/ios`) | Becomes |
|---|---|
| `Playback/Sources/Playback/AVAudioEnginePlaybackController.swift`, `Engine/BufferingPolicy.swift`, `Engine/MediaClock.swift`, `StreamingPCMReader.swift` | deleted; `Player<Episode>` with an `FFmpegItemSource` over `GrowingFileByteSource` |
| `PlaybackControlling`, `PlaybackControllerState`, `PlaybackControllerEvent` | `EngineAudioPlayerBridge` reads `Player` state and `events`; the protocol goes when nothing else reads it |
| session code in `ShuttlePodcastsApp.swift`, the controller's interruption and route handlers, `CarPlaySceneDelegate.configureAudioSession` | deleted; `AudioSessionConfiguration.spokenAudio`. `HeadphoneObserver` stays |
| `NowPlayingInfoManager`, `RemoteCommandHandler` | `NowPlayingSession` with the skip intervals from `WidgetIntentDefaults` and `supportedRates` from `CarPlayNowPlayingController.speeds` |
| `SilenceGate`, `VoiceEnhanceProcessor` | `AudioProcessor`s, unchanged from ADR-0018's plan |
| `SkipCueMixer` | the chime stays on its own player until the render layer mixes at the playhead; the duck is a `volume` ramp |
| `SleepTimerManager.kt`, `ObserveAndStorePlaybackPosition.kt`, `QueueAutoAdvanceManager.kt` | unchanged, over the bridge; the saver reads `position` in seconds |

| Shuttle2 (`ios`) | Becomes |
|---|---|
| `Playback/Sources/S2Playback/Engine/` (`MusicPlaybackController` and extensions, `PreopenLead`, `UnderrunResumeRule`, `TrackPCMSource`) | deleted; `Player<PlaybackTrack>`; `PlaybackTrack.makeSource` is the item factory |
| `S2/Platform/Audio/AudioEngine.swift`, `MusicPlaybackController+AudioEngine.swift` | deleted |
| `S2/Platform/Audio/AudioSessionController.swift` | deleted; its rules are the player's |
| `S2/Platform/Audio/NowPlayingController.swift` | `NowPlayingSession`; `PlaybackSystemCoordinator` keeps only the widget publisher and `PlayIntent` logging |
| `EngineAudioPlayer` | thin over `Player`: `load` is `setItems`/`replaceItems`, `setNext` goes (the list has the next), `setPauseAtEnd` is `pauseAtEndOfItem` |
| Kotlin `IosEngineFeeder.feedNext` | deleted; `IosEngineEvents.onCurrentFailed` stays as the `itemFailed` handler |
| `PCMProcessor` (ReplayGain, EQ, limiter) | `AudioProcessor`s and a gain `ItemSource` wrapper, as in ADR-0018's plan |

### Slices

| # | Title | Scope | Size | Depends on |
|---|---|---|---|---|
| 1 | Transport in seconds | `Transport.setCurrent(startSeconds:)` and `seek(item:toSeconds:)` (converted after open, frames kept inside); a failed next item is reported and dropped without pausing the current. Duration has landed (#115): `ItemSource.duration` in frames, carried by `TransportEvent.position(…, duration:)`. Useful alone: an app on `Transport` stops storing frames | S | #115 (landed) |
| 2 | `Player` core | product, item list and edits, state and `playWhenReady`, position and duration, seek within and across items, rate, volume, processors, `events`, `@Observable`; `FakeItemFactory`; the core and edit tests | M | 1, #116 |
| 3 | Advance, repeat, pause at end | pre-arm and `setNext` handoff, `.crossed` to `itemTransition`, `repeatMode`, `pauseAtEndOfItem`, `.ended`, per-item failure rules; the advance and error tests | M | 2 |
| 4 | Audio session | `AudioSessionControlling`, `SystemAudioSession`, `AudioSessionConfiguration`, activation, interruptions, route changes, media-services reset interplay; `FakeAudioSession`; the session tests | M | 2 |
| 5 | `PlaybackPlayerTestSupport` | the session seam and test initialiser widened to `@_spi(Testing)` (Testing above); public fakes, matching `PlaybackStreamingTestSupport`; one example test an app copies | S | 2, 4, #116 |
| 6 | `PlaybackNowPlaying` | `NowPlayingSession`: metadata closure, artwork, skip intervals or next/previous, `supportedRates`, elapsed written on change only; tests against a fake info centre and command centre (Shuttle2's `NowPlayingInfoCenter` and `RemoteCommandCenter` protocols are the model) | M | 3 |
| 7 | Docs and release | `usage.md` player section, `migrating.md` rewritten to the tables above, README product table, 0.10.0 | S | 2 to 6 |

Live processor parameters (#114) have landed, so this is not a slice here: `Transport.setProcessors` no
longer flushes, and parameter changes apply live. Only a change to a processor's `isActive` or output
format needs `setProcessors` called again.

## Alternatives rejected

- One `Player` that also owns Now Playing: links `MediaPlayer` into every consumer and couples the
  state machine's tests to `MPNowPlayingInfoCenter`; media3 keeps `MediaSession` apart for the same reason.
- `ShuffleOrder` in the player: a second, unpersisted record of an order both apps already keep in
  Kotlin and share with Android.
- A `PlaybackItem` struct with a URL instead of a generic `Item`: Shuttle2 needs headers, gain and a
  stream identity, Podcasts needs an episode id and a listener tap; a factory over the app's own type
  covers both with no `userInfo` bag.
- `CMTime`: a timescale we never need; the decoder's seek takes seconds and the frame unit stays in `Transport`.
- Combine `@Published` or a delegate: `@Observable` is what SwiftUI reads directly; a delegate is one
  more protocol with optional methods the apps would adapt into their own state anyway.
- A player actor rather than `@MainActor`: every caller (SwiftUI, remote commands, the Kotlin bridges) is
  on the main actor already, and an actor would make each read an `await`.
- Automatic skip of failed items with a cap: the two apps want different policies, and media3 stops.
- `rate = 0` as pause: `Transport` forbids it, and `playWhenReady` is the one record of intent.
- Overridable session rules (a closure per event): one mechanism per concern; the rules are the same in
  both apps once Podcasts' gaps are filled.
- Migrating onto `Transport` first: the adapters would be written twice.

## Consequences

- Both apps delete their engine, clock, scheduling, session and Now Playing code: about 2,700 lines in
  Podcasts and 1,700 in Shuttle2 beyond what ADR-0018 already removes.
- Position becomes seconds at the package boundary; frames stay inside `Transport`, so a stored resume
  point is seconds, and sample accuracy still holds because the seek converts at the item's rate.
- `Player` is `@MainActor`, so a Kotlin bridge calling from a background coroutine hops to main first.
- The player's list is a mirror of the app's queue, not its record. An app must call `replaceItems`
  when its queue changes; forgetting to do so plays the stale next item.
- Recovery still lands paused (ADR-0018), now with `playWhenReady` set false and an event; auto-resume
  after a media-services reset is not offered.
- `Transport` gains a seconds API and a changed failure rule (slice 1), a minor bump.
- The sleep-timer fade and the Smart Skip chime stay in the apps until the render layer can mix at the
  playhead, so Podcasts keeps a second `AVAudioPlayer` for the chime.

## Decided

- **Shuffle lives in the app.** Both queue models are Kotlin and shared with Android; the player takes
  the list in play order.
- **A failed item stops the player and is reported, with no auto-skip.** media3 stops with an error, the
  apps' policies differ, and the `itemFailed` handler is one place per app.
- **`Player<Item>` is generic.** Both apps' track types carry fields a URL cannot, and `Transport` is
  already generic.
- **No auto-resume after a media-services reset.** It lands paused with `recoveredPaused`, as ADR-0018
  says; revisit only if users report it.
- **Position is published on every pump.** `@Observable` redraws only the views that read `position`,
  and a saver samples at its own rate.
- **The product is `PlaybackNowPlaying`.** It names the Apple API it wraps, and "session" already means
  `AVAudioSession` here.
- **A pre-armed next item that fails no longer pauses the current one** (slice 1). `Transport` pauses on
  any item's failure today, which would stop an album because the track after the current one is corrupt.
- **Both apps migrate straight onto `Player`.** Moving onto `Transport` first writes the adapters twice.

Links: [ADR-0018](0018-render-layer.md), [ADR-0005](0005-shared-engine-repo.md),
[migrating](../migrating.md), [usage](../usage.md), issues #114, #115, #116; media3 `Player`,
`ExoPlayerImpl`, `MediaSession`, `AudioFocusManager`, `DefaultShuffleOrder`; `AVPlayer.timeControlStatus`,
`AVQueuePlayer`.
