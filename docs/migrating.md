# Migrating Shuttle Podcasts and Shuttle2 to Player

Both apps move their `AVAudioEngine` playback straight onto `Player` ([ADR-0019](decisions/0019-player.md)),
not onto `Transport` first: each would write the session, state machine and advance code once for
`Transport` and delete it again for `Player`. [Usage](usage.md#play-a-list-with-player) has the API; this
page has what each app does today, where it goes, and the order of work. Paths are relative to each app's
iOS directory (`mobile/ios` in `timusus/shuttle-podcasts`, `ios` in `timusus/shuttle2`).

## Prerequisites

- **Pin the 0.10.0 tag or later**, never a branch. Add `PlaybackPlayer` and `PlaybackNowPlaying` next to
  `PlaybackDecode` and `PlaybackStreaming`; the test targets add `PlaybackPlayerTestSupport`.
- **Embed `FFmpeg.framework` once**, in the app target. Both apps already do; check that the package's
  `FFmpeg` product and any FFmpeg of the app's own are not both linked.
- **The package owns** the audio session (category, lazy activation, interruptions, route loss, media-services
  reset), the engine, clock and scheduling, the advance to the next item, the failure rules, and the lock
  screen and remote commands.
- **The apps keep** the queue and its order (shuffle is Kotlin in both, shared with Android), persistence of
  positions, sleep timers, auto-play on headphones, and every effect's algorithm.
- **Threading.** `Player` is `@MainActor`, and both Kotlin bridges (`IosAudioPlayer`) are called on the
  main thread only, so a bridge calls the player directly. Podcasts' `EngineAudioPlayerBridge.onMain` stays
  synchronous, to keep Kotlin's ordering.

## Where things go

| Concern | Today | In the package |
|---|---|---|
| Queue and current item | Podcasts: one episode, Kotlin `QueueAutoAdvanceManager` loads the next on `Ended`. Shuttle2: `load(current:next:)` and `setNext` | `setItems`, `replaceItems(_:currentIndex:)`, `insert`, `move`, `remove`; the player arms the next item itself |
| Play, pause | `resume()`, `pause()`; `isPlayIntended` / `isPlaying` | `play()`, `pause()`, `playWhenReady` (intent), `isPlaying` |
| Skip | `seekForward(seconds:)`, queue skips in Kotlin | `seek(by:)`, `skipToNext()`, `skipToPrevious()` |
| Seek | `seek(toMilliseconds:)`, `SeekCompleted` from Kotlin | `seek(to:)` in seconds; `PlayerEvent.seekLanded` when the audio is heard |
| Position, duration | 0.5 s (Podcasts) or 100 ms (Shuttle2) timer, ms | `position`, `duration` in seconds, `discontinuityCount` to tell a jump from listening |
| State | `PlaybackControllerState`, Shuttle2 `State` | `PlaybackState` plus `playWhenReady` and `suppression`; see the table below |
| Speed, volume | `setPlaybackSpeed`, `sleepFadeGain` | `rate`, `volume` |
| Pause at end of episode or track | Shuttle2 `setPauseAtEnd`, `onPausedAtEnd` | `pauseAtEndOfItem`, `PlayerEvent.playWhenReadyChanged(_, reason: .endOfItem)` |
| Failed item | Podcasts: stops. Shuttle2: `onCurrentFailed` skips up to 15 | stops with `error`; `PlayerEvent.itemFailed` is the one handler, which calls `skipToNext()` for Shuttle2's policy |
| Interruptions, route loss, media-services reset | `AVAudioEngine` controller handlers (Podcasts), `AudioSessionController` (Shuttle2) | the player: see [the audio session](usage.md#the-audio-session) |
| Now Playing, remote commands | `NowPlayingInfoManager` + `RemoteCommandHandler`, `NowPlayingController` + `PlaybackSystemCoordinator` | `NowPlayingSession` |
| Skip-silence, Voice Boost, ReplayGain, EQ, limiter | processors in the engine graph | `AudioProcessor`s given to `setProcessors(_:)` |
| Fades and ducks | mixer gain | `volume` ramps from the app's timer |

State mapping, for both apps' adapters:

| App state | `Player` |
|---|---|
| idle | `.idle` and `error == nil` |
| loading, buffering | `.buffering` (an item opening, or decode behind the clock) |
| playing | `isPlaying` |
| paused | `.ready` and not `playWhenReady`; also `suppression == .interruption` when the system paused it |
| ended | `.ended` |
| error | `.idle` with `error` set, and `itemFailed` |

### Effects: a processor or the app?

An effect that changes the audio of an item is an `AudioProcessor`: skip-silence, Voice Boost (with its
limiter), ReplayGain, the EQ. Anything that changes the level over time is `player.volume` written from
the app's timer, because a processed change is heard about two seconds late: the sleep-timer fade, a duck,
the skip layer's pre-seek fade. An effect that is not the item's audio stays in the app: Podcasts' Smart
Skip chime plays on its own `AVAudioPlayer` until the render layer mixes at the playhead. See
[Writing a processor](#writing-a-processor).

### Shuttle Podcasts

| Today | File | Becomes |
|---|---|---|
| `AVAudioEnginePlaybackController` (about 2,700 lines), `Engine/BufferingPolicy`, `Engine/MediaClock` | `Playback/Sources/Playback/` | deleted; one `Player<Episode>` with `audioSession: .spokenAudio` |
| `EngineAudioPlayerBridge` (the `IosAudioPlayer` adapter) | `ShuttlePodcasts/Platform/Audio/AVAudioEnginePlaybackController+IosAudioPlayer.swift` | the adapter that remains: `load(url:episodeId:positionMs:playWhenReady:)` is `setItems([episode], startPosition:)` then `play()` if asked, `seek(positionMs:)` is `seek(to:)` over 1000, `setSpeed` is `rate`, `setVolume` is `volume` |
| `PlaybackControlling`, `PlaybackControllerState`, `PlaybackControllerEvent` | `PlaybackControlling.swift` | the bridge publishes them from `Player` state and `events`, until nothing else reads them |
| `StreamingPCMReader` | `StreamingPCMReader.swift` | `FFmpegItemSource(reader: GrowingFileByteSource(...))` in the `makeSource` closure, with the ad-skip scan's `GrowingFileListener` tap attached to the source |
| `SilenceGate`, `VoiceEnhanceProcessor`, `LookaheadLimiter` | `Sources/SilenceGate/`, `Sources/VoiceEnhance/` | `AudioProcessor`s, in that order, passed to `setProcessors` |
| `PlaybackEnhancementTracker` (reads `pref_skip_silence`, `pref_voice_enhance` per buffer) | `PlaybackEnhancementSettings.swift` | a processor flag read under the processor's lock; `setProcessors` only if `isActive` or the output format changes |
| `SkipCueMixer` | `SkipCueMixer.swift` | chime on its own player; the duck is a `volume` ramp |
| Sleep-timer fade, `SleepTimerManager.kt` | the controller, Kotlin | `volume` ramp; the timer calls `pause()`, or sets `pauseAtEndOfItem` for "end of episode" |
| session setup in `ShuttlePodcastsApp.swift`, interruption and route handlers, `CarPlaySceneDelegate.configureAudioSession` | | deleted. `HeadphoneObserver` stays: auto-play on connect is a preference |
| `NowPlayingInfoManager`, `RemoteCommandHandler` | `Platform/Audio/` | `NowPlayingSession(player: wrapper, supportedRates: CarPlayNowPlayingController.speeds, ...)`, where the `ForwardingNowPlayingControllable` wrapper's `skipIntervals` come from `WidgetIntentDefaults` |
| `ObserveAndStorePlaybackPosition.kt` | Kotlin | unchanged: it reads `position` in seconds, and counts listening only while `discontinuityCount` is unchanged |

Details:

1. `isPlayIntended` becomes `playWhenReady`. It is the app's intent and moves on `play()`, `pause()`, and
   the player's own `.routeLost`, `.interruptionEnded` and `.endOfItem` changes; observe those through
   `playWhenReadyChanged` so Kotlin's play state follows.
2. `episodeEnded` is `state == .ended`; Kotlin loads the next queued episode with another `setItems`.
3. `durationChanged` is `duration` becoming non-nil, in seconds; fall back to the feed's duration while it is nil.
4. Smart Skip's `seekLanded` is `PlayerEvent.seekLanded`; an ad range is `player.seek(to: cue.end)`.
5. `NowPlayingSession` replaces both the info and command code, with `spokenAudio` behaviour: skip
   intervals instead of next and previous, `supportedRates` for the rate command. The wrapper takes the
   commands over: its `rate` setter saves the speed in Kotlin before setting `player.rate`, and its
   `seek(by:)` applies the app's own skip rules.
6. A `recoveredPaused` event is new to Podcasts, which never handled a media-services reset: show paused,
   and let the user press play.

### Shuttle2

| Today | File | Becomes |
|---|---|---|
| `MusicPlaybackController` and its `+Output`, `+Stream`, `+Timeline`, `+Underrun`, `+Opening` extensions, `PreopenLead`, `UnderrunResumeRule` | `Playback/Sources/S2Playback/Engine/` | deleted; one `Player<PlaybackTrack>` |
| `PlaybackTrack` (`uid`, `gainDb`, `makeSource`) | `PlaybackTrack.swift` | the `Item`; `makeSource` is the `makeSource` closure |
| `TrackPCMSource`, `FFmpegTrackSource` | `TrackPCMSource.swift` | `FFmpegItemSource(reader:)`; no conversion to a fixed output format. A progressive transcode is the app's own `ItemSource`, below |
| `PCMProcessor`: ReplayGain, `EqualizerSettings`, `LimiterSettings` | `DSP/PCMProcessor.swift` | `AudioProcessor`s: ReplayGain first, picking the gain in `flush(_:)` (ADR-0021), then EQ and limiter |
| Short-end re-open (an item ending before its duration is re-opened at the position, up to 3 tries) | `Engine/` | app-owned: the package plays a short end as the end, so the app re-opens from its `itemTransition` handler and counts the tries |
| Start-up timing logs | `Engine/` | app-owned, timed from `events` and the observed `state` |
| `+Reporting`, `+Slot`, `+StartTiming` controller extensions | `Engine/` | deleted with the controller; what the app still reports it reads from `events` |
| `AudioEngine.swift`, `MusicPlaybackController+AudioEngine.swift` | `S2/Platform/Audio/` | deleted |
| `AudioSessionController` | `S2/Platform/Audio/` | deleted; its rules are the player's. `.longFormAudio` is its category and route sharing |
| `NowPlayingController` | `S2/Platform/Audio/` | `NowPlayingSession(player: sessionPlayer, ...)`, a `ForwardingNowPlayingControllable` for the queue rules, as Android's `SessionPlayer : ForwardingPlayer`. `PlaybackSystemCoordinator` keeps only the widget publisher and `PlayIntent` logging |
| `EngineAudioPlayer` (the `IosAudioPlayer` adapter) | `S2/Platform/Audio/EngineAudioPlayer.swift` | thin over `Player`: `load` is `setItems` or `replaceItems`, `setNext` goes, `setPauseAtEnd` is `pauseAtEndOfItem`, `stop()` is `stop()` |
| Kotlin `IosEngineFeeder.feedNext` | `shared/` | deleted; `IosEngineEvents.onCurrentFailed` stays as the `itemFailed` handler |
| `QueueModel` shuffle order | Kotlin | unchanged; hand the player `queue.playOrder`, and `replaceItems` on every edit or shuffle toggle |

Details:

1. `onStateChanged` is `state`, `playWhenReady` and `suppression`; `onTransition` is `itemTransition`;
   `onFailed` is `itemFailed`; `onPosition` is `position` (seconds times 1000 for the Kotlin millisecond
   callbacks). The `commands` / `superseded` count the adapter keeps goes: `Player` drops a stale event
   itself.
2. **ReplayGain.** `gainDb` is per track: a first processor, ahead of the EQ and limiter, picks the gain
   for `metadata.item` in `flush(_:)`, which names the item whose frames follow (ADR-0021).
3. **EQ.** The coefficients come from the shared Kotlin code for one rate. The processor's `configure(_:)`
   gets the item's rate and must ask for coefficients for it, again after each `flush(_:)` that follows a
   rate change. Never cache a 44.1 kHz set.
4. **Limiter and EQ state across a join.** Every join drains, re-configures and flushes the pipeline,
   so filter memory and the limiter envelope reset there, whatever the format.
5. **Remove the fixed output format.** Each item plays at its own sample rate and channel count, so
   `PCMProcessor` loses its assumption of stereo at `outputSampleRate`.
6. **Progressive transcodes** (`onSeekUnsupported` today): the app's `ItemSource` streams the transcode
   with no length, declares `isSeekable` true, and seeks by re-opening the server stream at a time offset
   (ADR-0022). The player then offers the scrubber and does not treat the item as live; a landing more than
   1 ms off the target arrives as `seekAdjusted`.
7. **Failed tracks.** `onCurrentFailed` skips only an item that never became ready, never wraps past the
   end of the queue, and stops after 15 in a row. Keep those rules in the `itemFailed` handler, counting
   there: `skipToNext()` wraps under `repeatMode = .all`, so check `currentIndex` first.
8. **Command policy.** The queue rules for remote commands live in the `ForwardingNowPlayingControllable`
   wrapper (ADR-0020): its `availableCommands` greys a command out, and it overrides `seekToNext()` and
   `seekToPrevious()` where the queue decides.
9. **Crossfade** does not exist on iOS; the join is gapless, and a fade at a track end is a `volume` ramp.
10. **Repeat one** is `repeatMode = .one`, the same item twice in a row, gapless.

## Order of work

Each step ships on its own. Put the new path behind a flag until step 4; the adapter is the surface to rewrite.

1. **Pin the tag and add the products.** Build and run; nothing changes.
2. **Build a `Player` behind the flag in the adapter.** With the flag on, `makeSource` returns the
   `FFmpegItemSource` the app builds today, and the adapter maps `Player` state and `events` onto the
   existing Kotlin callbacks. Leave effects off in this path, and `NowPlayingSession` out.
3. **Port the effects** one at a time as `AudioProcessor`s, in the order they run today, and compare each
   against the old output on a recorded clip. Then swap Now Playing to `NowPlayingSession`.
4. **Make the flag the default, then delete** the old graph (engine, mixers, clock code, scheduling, the
   session and Now Playing code in the table above) and the flag. Keep the effect algorithms' tests; they
   now test the processors.
5. **Test the app's coordinator** with `PlaybackPlayerTestSupport` (see [usage](usage.md#test-code-built-on-player)).
6. **Run the device checklist** ([device-checklist.md](device-checklist.md)), once with the flag off and
   once on, and compare.

## Writing a processor

- `configure(_:)` receives the item's `PCMFormat` and returns the output format; with `isActive` false the
  stage is skipped. A format that changes the sample rate throws `AudioProcessingError.sampleRateChanged`.
- `configure(_:)` only stages and `flush(_:)` applies, so a rate-dependent filter rebuilds in `flush(_:)`,
  which also names the item whose frames follow. A
  toggle or gain the app changes while playing is read under the processor's own lock.
- A stage that removes audio (a silence gate) reports each removal as `DroppedFrames`, in input frames, at
  the output frame it precedes. Positions then stay in media time, which is what the ad-skip arithmetic and
  the saved resume point use.
- A stage never adds frames. Mixing into existing frames is fine; inserting is not.

## Pitfalls

- **Effects are heard about two seconds after they are processed.** The transport keeps PCM written ahead
  of the playhead. Fades, ducks and mutes go through `volume`, written repeatedly from the app's timer;
  never from a processor.
- **A toggle is heard about two seconds late, without a gap.** A processor's own parameters apply live
  from the next chunk it processes, and `setProcessors` drains the old chain and swaps at the next chunk;
  neither flushes. Call `setProcessors` only when the chain, `isActive` or the output format changes.
- **Recovery lands paused.** A renderer failure or media-services reset is rebuilt once; the player sets
  `playWhenReady` false and sends `recoveredPaused`. The app calls `play()` if the user still means to
  play. Do not add a second recovery layer, and do not observe the session notifications yourself.
- **The list mirrors your queue.** Call `replaceItems` when the queue or its shuffle order changes, or the
  next item is stale.
- **`rate` is not pause.** Pause is `playWhenReady = false`.
- **Positions are seconds.** A stored resume point is seconds; the seek converts at the item's own sample
  rate, so it lands on the frame it was reported at.
- **A source belongs to one item.** The factory makes a new `FFmpegItemSource` per call.
- **`Player` is main-actor.** A Kotlin bridge called from a background coroutine hops to main first.

## If you only need `Transport`

An app that keeps its own queue and session can drive `Transport` directly
([usage](usage.md#play-through-the-render-layer)); nothing in the package requires `Player`. Then the
session is yours: activate it before `play()`, pause on an interruption's `began` and call `play()` on
`ended` with `shouldResume`, and on `TransportEvent.recovered` show paused. Neither app does this.
