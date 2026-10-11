# Migrating an AVAudioEngine player to PlaybackRender

How Shuttle Podcasts and Shuttle2 replace their `AVAudioEngine` playback with `Transport`
([ADR-0018](decisions/0018-render-layer.md)). [Usage](usage.md#play-through-the-render-layer) has the API;
this page has the order of work and the traps. Paths are relative to each app's iOS directory.

## Prerequisites

- **Pin the 0.9.0 tag or later**, never a branch. Add the `PlaybackRender` product next to
  `PlaybackDecode` and `PlaybackStreaming`.
- **Embed `FFmpeg.framework` once**, in the app target. Both apps already do; check that the package's
  `FFmpeg` product and any FFmpeg of the app's own are not both linked.
- **The app keeps** the `AVAudioSession` (category, activation, interruptions, route changes), Now
  Playing and remote commands, the queue and auto-advance, persistence of positions, and every effect's
  algorithm. The transport never touches the session: activate it before `play()`.
- **The app deletes** its engine graph, clock anchoring, scheduling budget, engine restart after an
  interruption or configuration change, and underrun detection. The render layer has one restart path
  for all of them.

## Concept map

| Here | Is | In `PlaybackRender` |
|---|---|---|
| Current and next track handed over | what to play | `setCurrent(item:source:startSeconds:)`, `setNext(item:source:)`, `clearNext()` |
| The queue entry's id | its name in events | the transport's `Item` type (`Hashable & Sendable`) |
| Decoder behind a byte source | PCM for one track | `FFmpegItemSource(reader:)` over `FileByteReader` or `GrowingFileByteSource` |
| A DSP stage | PCM in, PCM out | `AudioProcessor`, passed to `setProcessors(_:)` |
| Frames a stage removes | keeps position in media time | `ProcessorOutput.dropped` (`DroppedFrames`) |
| Position tick | what is heard | `TransportEvent.position(item:seconds:duration:)` |
| Next track reached the speaker | | `TransportEvent.crossed(item:)` |
| Playing, buffering, paused, ended | | `TransportEvent.status(_:)` with `TransportStatus` |
| A track or output failed | | `TransportEvent.failed(item:error:)` |
| A seek or track change taken; events before it are stale | | `TransportEvent.sought(item:seconds:)` |
| Speed, volume | | `setRate(_:)`, `setVolume(_:)` |

### Shuttle Podcasts

| Today | File | Becomes |
|---|---|---|
| `AVAudioEnginePlaybackController` | `Playback/Sources/Playback/AVAudioEnginePlaybackController.swift` | a thin `PlaybackControlling` over one `Transport<String>` (the episode id) |
| `PlaybackControlling`, `PlaybackControllerState`, `PlaybackControllerEvent` | `PlaybackControlling.swift` | unchanged; the app's surfaces keep reading them |
| `StreamingPCMReader` | `StreamingPCMReader.swift` | `FFmpegItemSource(reader: GrowingFileByteSource(...))` |
| `SilenceGate` (`SilenceGateSettings`) | `Sources/SilenceGate/SilenceGate.swift` | an `AudioProcessor` whose `dropped` carries `skippedFrames` |
| `VoiceEnhanceProcessor`, `LookaheadLimiter` | `Sources/VoiceEnhance/` | an `AudioProcessor` after the gate |
| `PlaybackEnhancementTracker` (reads `pref_skip_silence`, `pref_voice_enhance` each buffer) | `PlaybackEnhancementSettings.swift` | a toggle that calls `setProcessors` |
| `SkipCueMixer`: chime and content duck | `SkipCueMixer.swift` | see the gaps under Shuttle Podcasts below |
| Sleep-timer fade mixer | the controller | a `setVolume` ramp |
| `SkipPlayerPort`, `SpinePlaybackCoordinator` | `ShuttlePodcasts/Platform/Audio/Spine/` | unchanged; fed by `.position`, `.status`, and the seek and volume calls |

### Shuttle2

| Today | File | Becomes |
|---|---|---|
| `MusicPlaybackController` and its `+Output`, `+Stream`, `+Timeline`, `+Underrun`, `+Opening` extensions | `Playback/Sources/S2Playback/Engine/` | a thin wrapper over one `Transport<String>` (the track `uid`) |
| `PlaybackTrack` (`uid`, `gainDb`, `makeSource`) | `PlaybackTrack.swift` | the `Item` plus an `ItemSource` built by the same factory |
| `TrackPCMSource`, `FFmpegTrackSource` | `TrackPCMSource.swift` | `FFmpegItemSource(reader:)`; no conversion to a fixed output format |
| `PCMProcessor`: ReplayGain, `EqualizerSettings`, `LimiterSettings` | `DSP/PCMProcessor.swift` | `AudioProcessor`s |
| `PreopenLead`, `UnderrunResumeRule` | `Engine/` | deleted |
| `onStateChanged`, `onTransition`, `onFailed`, `onPosition` | `MusicPlaybackController.swift` | `.status`, `.crossed`, `.failed`, `.position` |
| `outputSampleRate` (fixed, stereo) | | gone: each item plays at its own rate and channel count |

## Order of work

Each step ships on its own. Put the new path behind a flag until step 5.

1. **Add the dependency and a `Transport` the app does not call yet.** Build and run; nothing changes.
2. **Move decode first.** Replace the app's reader with `FFmpegItemSource` and keep the engine graph by
   pulling PCM through a small adapter. This tests the byte source, seek landing and end-of-stream with
   the old output still in place. Skip this step if the app already uses `FFmpegStreamDecoder`.
3. **Render behind the flag.** With the flag on, build a `Transport`, set the current item, and map
   `TransportEvent` onto the app's existing state and events. Leave effects off in this path.
4. **Port the effects** one at a time as `AudioProcessor`s, in the order they run today, and compare each
   against the old output on a recorded clip.
5. **Make the flag the default, then delete the old graph** (engine, node, time-pitch, mixers, clock
   code, scheduling) and the flag with it. Keep the effect algorithms' tests; they now test the processors.

## Writing a processor

- `configure(_:)` receives the item's `PCMFormat` and returns the output format; with `isActive` false the
  stage is skipped. A format that changes the sample rate throws `AudioProcessingError.sampleRateChanged`.
- `configure(_:)` only stages and `flush()` applies, so a rate-dependent filter rebuilds in `flush()`. A
  toggle or gain the app changes while playing is read under the processor's own lock.
- A stage that removes audio (a silence gate) reports each removal as `DroppedFrames`, in input frames, at
  the output frame it precedes. Positions then stay in media time, which is what the ad-skip arithmetic and
  the saved resume point use.
- A stage never adds frames. Mixing into existing frames is fine; inserting is not.

## Shuttle Podcasts

1. `play(url:episodeId:startPositionMs:)` becomes `setCurrent(item: episodeId, source:, startSeconds:)`,
   with `startSeconds` the saved position over 1000.
2. Build the `GrowingFileByteSource` as `StreamingPCMReader` does today, including the `GrowingFileListener`
   the ad-skip scan reads the file through (`onEvent`); the bytes the scan sees are still the bytes decoded.
3. Map events: `.position` to `currentPosition` and `playerEvents.playbackPositionChanged`; `.status(.buffering)`
   to `PlaybackControllerState.buffering`; `.status(.ended)` to `.ended` and `episodeEnded`; `.failed` to
   `.error`. `isPlayIntended` stays the app's own flag, set on the call and not on the event.
4. `seek` calls `seek(item:toSeconds:)`; the `seekLanded` event is sent when the app next sees a `.position`
   at or past the target.
5. Order the chain as it runs today: `SilenceGate`, then `VoiceEnhanceProcessor`. Toggling either sets a
   flag the processor reads under its lock, or calls `setProcessors`; neither flushes.
6. The sleep-timer fade and the skip layer's pre-seek fade are `setVolume` ramps from the app's timer.
7. Delete `reanchorAfterEngineRestart`, `restartEngineIfNeeded`, `recoverStalledClock` and the schedule
   budget, and `BufferingPolicy`'s clock-stall handling: the transport owns them.

### Gaps for Podcasts

- **The chime and the duck.** `SkipCueMixer` mixes a chime on the first frames produced and ducks the
  podcast samples only. As a processor the chime would sound about two seconds late, and `setVolume`
  would duck the chime too. Play the chime on a separate player until the render layer has a playhead-time
  mix; keep the duck as a `setVolume` ramp.
- **Duration.** `durationChanged` comes from the `duration` on `.position`, in seconds as FFmpeg probed
  the file; fall back to the episode's metadata only when it is nil.

## Shuttle2

1. `load(current:next:startMs:playWhenReady:)` becomes `setCurrent(item: uid, source:, startSeconds:)`,
   then `setNext(item:source:)` for the following track, and again whenever the queue changes. Create a
   new `FFmpegItemSource` for each call.
2. Delete `PreopenLead`, `UnderrunResumeRule` and the pre-open queue; the transport decodes the next item
   ahead and rides through an underrun.
3. Remove the fixed output format. Every item plays at its own rate and channel count, so
   `PCMProcessor` loses its assumption of stereo at `outputSampleRate`.
4. **EQ.** The coefficients are computed by the shared Kotlin code for one rate. The processor's
   `configure(_:)` gets the item's rate and must ask for coefficients for that rate; do the same after each
   `flush()` that follows a rate change. Never cache a 44.1 kHz set.
5. **Limiter and EQ state across a join.** Filter memory and the limiter envelope used to run on across
   tracks. With a format change at a join the pipeline re-configures and flushes, so the state resets
   there; with the same format it carries on.
6. **ReplayGain.** `gainDb` is per track and processors do not see which item a chunk belongs to. Apply it
   in an `ItemSource` that wraps `FFmpegItemSource` and scales each chunk in `nextChunk()`, ahead of the
   chain, so the EQ and limiter see gained audio as they do now.
7. Map events: `.position` to `onPosition` (seconds times 1000 for milliseconds), `.crossed` to
   `onTransition`, `.failed` to `onFailed`, `.status` to `onStateChanged`. `idle` and `loading` stay the
   app's states. The command count in `onStateChanged` stays with the wrapper.
8. **Pause at end.** `setPauseAtEnd(true)` becomes not calling `setNext` until the app wants the next
   track: the transport reports `.status(.ended)` at the last frame, and a later `setNext` plays on.
9. **Progressive transcodes** (`isSeekable` false, `onSeekUnsupported`): the app re-opens the stream at the
   position with a new `setCurrent(item:source:startSeconds:)`. An `ItemSource.seek` that throws arrives as
   `.failed`, so the wrapper must decide before calling `seek(item:toSeconds:)`.

## Pitfalls

- **Effects are heard about two seconds after they are processed.** The transport keeps PCM written ahead
  of the playhead. Fades, ducks and mutes go through `setVolume`, called repeatedly from the app's timer;
  never from a processor.
- **A toggle is heard about two seconds late, without a gap.** A processor's own parameters apply live
  from the next chunk it processes (including an "enabled" flag it reads inside a stage that stays
  `isActive`), and `setProcessors` drains the old chain and swaps at the next chunk; neither flushes.
  Call `setProcessors` only when the chain, `isActive` or the output format changes.
- **Recovery lands paused.** A failed renderer or a media-services reset is rebuilt once and the transport
  lands paused at the same position. The app calls `play()` again when it still means to play. A second
  failure surfaces as `TransportEvent.failed`, and `play()` does nothing until a `seek`, `setCurrent` or
  `setProcessors`. Do not add a second recovery layer.
- **Positions are seconds; frames stay inside.** A start or seek lands on the nearest frame once the item
  has opened, so a reported position seeks back to the frame it came from at any rate.
- **`setRate` is not pause.** Rate 0 is not allowed; call `pause()`.
- **Set the session before `play()`**, and handle interruptions yourself: pause on `began`, call `play()`
  on `ended` with `shouldResume`.
- **A source belongs to one `setCurrent` or `setNext`.** Never reuse it.
- **The events arrive on the transport's queue.** Hop to the main actor before touching `@Published` state.

## Checklist

Run each on a device, once with the flag off and once on, and compare.

Both apps:

- Interruption (a call, Siri, an alarm) begins and ends, with and without `shouldResume`.
- Route changes: headphones unplugged, Bluetooth connect and disconnect, speaker to AirPlay and back.
- AirPlay 2 playback for several minutes: position stays aligned with what is heard.
- Settings, Developer, Reset Media Services (or `killall mediaserverd`): playback lands paused at the same
  position, and `play()` resumes it.
- Speed changes (1x, 1.5x, 2x, back) in media time, paused and playing; a seek while paused.
- Seeks: start, middle, and the last second; a seek during a stalled stream.
- A streamed item from a cold start: time to first audio against the old path, then a dropped connection
  mid-play, and resume without re-download.
- Airplane mode on and off during a stream; the item resumes when the network returns.
- A corrupt or unsupported file: `.failed` once, no loop.
- Locking the phone and backgrounding: audio continues, position correct on return.
- A saved position restores to the same sample.

Shuttle Podcasts also:

- Skip silence on and off mid-episode; the displayed position and the savings counter stay in media time.
- Voice Boost on and off mid-episode, with no gap or click.
- Smart Skip: scan, seek past an ad, the chime, the duck, undo.
- Sleep timer fade out.
- Continue Listening restores to the saved position after a seek and after a force quit.

Shuttle2 also:

- Gapless albums at mixed sample rates (44.1, 48, 96 kHz): no gap, no click, `.crossed` at the join.
- ReplayGain between a loud and a quiet track, in track and album mode.
- EQ on and off, and on tracks of different rates; limiter on a boosted track.
- Skip next and previous quickly; the queue changing under a pre-opened next track.
- Pause at end of track; the next starts on play.
- A progressive transcode: seek re-opens at the position.
- Repeat one: the same item twice in a row.
