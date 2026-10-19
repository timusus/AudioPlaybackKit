# ADR-0018: A render layer over AVSampleBufferAudioRenderer

Status: Accepted
Date: 2026-10-11

## Context

Both apps hand-roll output on `AVAudioEngine` + `AVAudioPlayerNode` + `AVAudioUnitTimePitch`
(podcasts about 2,700 lines, Shuttle2 about 1,700). Each has re-derived the same clock and scheduling
rules, and they share bugs:
- The time-pitch unit holds about 81 ms and runs the node clock 3584 frames ahead even at 1x. After
  a paused seek it plays stale audio (podcasts #396).
- `playerTime(forNodeTime:)` is nil while paused (#397, Shuttle2 #714).
- Output latency is added by hand.
A macOS spike (`Spikes/RenderSpike` on `worktree-render-spike`) reproduced all three on the engine.
On `AVSampleBufferAudioRenderer` with `AVSampleBufferRenderSynchronizer` it measured:
- after `flush()` + `setRate(0, time: 10)` the clock reads exactly 10.000000;
- while paused the clock is frozen and readable;
- output latency is already included;
- drift is 9 ppm against the host clock;
- a 1 → 2 → 1 rate change stays in media time with no auto-flush;
- 44.1k mono → 48k stereo mid-stream gives no error.
It also measured three gaps:
- the clock runs on through an underrun with no notification;
- PTS holes and overlaps are accepted silently;
- the renderer pulls once a second with near-zero headroom.

An iPhone probe (iOS 26.6, speaker, measured by microphone) confirmed the choice and added:
- `currentTime()` runs 11 ms ahead of what is heard, about `outputLatency` (9.7 ms). Unlike macOS,
  output latency is not included, so the adapter reports it and the timeline adds it.
- Each rate change drops out: 97 ms to 2x and 140 ms back with `.timeDomain`, 186 and 327 ms with
  `.spectral`.
- A format change at a join dips 8-11 ms, while the hardware rate stays 48 kHz (the renderer resamples).
  No dip at 96k → 192k.
- An output-port override or a category change auto-flushes within 10 ms. A `setActive` cycle and
  `setPreferredSampleRate` do not.
- A PTS hole plays as silence. An overlap trims the later audio to the timeline.
- The default pull cadence gave no glitches in 40 s, so depth is about latency, not dropouts.
- `flush()` blocks 74-80 ms and a rate change 41-49 ms, on any thread.

## Decision

We will add a `PlaybackRender` product, which depends on `PlaybackDecode` only.

It holds four parts:
- **An `AudioProcessor` pipeline** with media3 `AudioProcessingPipeline` semantics on Float32 interleaved: configure, then flush to apply; inactive processors are skipped; drain at end of stream.
- **A `MediaPositionMap`** with media3 `applyMediaPositionParameters` semantics. Dropped frames are credited when the playhead reaches them, not when they are processed. Item boundaries are reported on crossing.
- **A current-plus-next scheduler** that joins items gaplessly at each item's native rate and channel count.
- **One `AudioOutput` seam** over ASBAR and the synchronizer.

The core assigns contiguous output timestamps itself. It detects underruns from the clock passing the enqueued end. It writes while the output is ready for more (`isReadyForMoreMediaData`, re-armed with `requestMediaDataWhenReady`), so the renderer decides how far ahead it buffers, as media3's `DefaultAudioSink` writes while its `AudioTrack` takes data. A fixed 2 s lead played choppily over AirPlay and an 8 s one smoothly; a lead of latency plus 1 s was still choppy, so no depth the core picks fits every route (timusus/shuttle2#1064). Whatever the output takes, at most 30 s of media is written ahead, under media3's 50 s `maxBufferMs`. That bounds time, not bytes: about 11 MB at 48 kHz stereo Float32, several times that at a high sample rate or channel count. Fill, underrun and resume are all judged from `currentTime()`, never from the heard playhead, so nothing is stamped behind a running clock; output latency only offsets the reported position and heard events (#128, #183). The first start, and a start after a seek, re-feed or pause, waits for `resumeDepth` (0.5 s); a resume after an underrun waits for `rebufferDepth` (2 s), or until the output takes no more, so a flaky stream gives one longer pause, not a run of short stalls, as media3's `DefaultLoadControl` (`bufferForPlaybackMs` against `bufferForPlaybackAfterRebufferMs`; timusus/shuttle2#1064). Processors run at write time, so `setProcessors` and `processorsChanged` re-feed the audio written ahead with a partial flush (`flush(fromSourceTime:)`) rather than wait out up to 30 s of it; a normal start requires `resumeDepth` written, and only a rebuffer starts early on an output that reports full. Speed is the synchronizer rate, applied by the output, not at write time. The effects stay in the apps ([ADR-0005](0005-shared-engine-repo.md)), as processors.

### Layering

Each layer depends only on the one below it. Only one thing crosses a boundary: a *tagged chunk*,
which is PCM plus segment tags mapping its output frames to (item, media frame). A feature is a
component in one layer, and the layers beneath see only the tags it produced, never the feature.

| Layer | Owns | Does not know |
|---|---|---|
| Transport | play, pause, seek, set next, speed. It turns each into epochs and calls downward | PCM, timestamps |
| Sequencer | current and next item sources, and the join between them through one `Transition` strategy | processors, output |
| Pipeline | the processors, which transform chunks and rewrite tags when they drop or add frames | items, transport |
| Feeder | contiguous output timestamps, depth ahead of the clock, underruns, flush and re-feed | why a tag says what it says |
| Timeline | `MediaPositionMap` from the played output frame to (item, media frame), and boundary crossings | transitions, effects |
| Output | the `AudioOutput` seam and its ASBAR adapter, or a fake | everything above |

How features fit:
- A gapless join is the default `Transition`, which concatenates.
- Crossfade is a second `Transition` in its own file. It reads A's tail and B's head, brings B to A's format for the overlap, mixes them, and tags the overlap frames to whichever item should report the position. Nothing else changes.
- Skip-silence and ad cuts are pipeline processors that drop frames and rewrite tags.
- Speed is the transport setting the output rate.
- None of them adds a branch to the feeder, the timeline or the output. A feature that needs one is designed wrong.

### Effect changes

A parameter (a gain, EQ bands, a toggle) applies live under the processor's own lock from the next chunk
it processes, and a chain change swaps at the next chunk. Both would be heard only after the up to 30 s
already written, so `Transport.setProcessors` and `processorsChanged()` re-feed with a partial flush: the output drops what
is stamped from `resumeDepth` past the clock, and the feeder rewinds the position map and the upstream to that
cut and writes it again, so audio before it keeps playing, with no `buffering` status. media3's `DefaultAudioSink` drains to the end of
stream on a pending configuration, but with up to 30 s queued that would delay the effect too long, so
we deviate; the change is heard about `resumeDepth` late. Calls made while a partial flush is pending fold
into it (the next pulled chunk carries the newest parameters), so a slider cannot pile up flushes. If the
completion reports failure (the cut has passed) the feeder takes the full restart path, as a seek does,
and rebuffers briefly. Whether an AirPlay receiver survives a partial flush is checked on device (#1064). After `.ended` nothing is re-fed (the chain applies to the
next audio), and `processorsChanged()` does nothing while failed. A fade goes through `setVolume`, which needs no flush.

### Recovery

A failed renderer is terminal. This happens through its `status`, a failed enqueue, or an iOS media-services reset. The feeder then rebuilds the output and restarts from the heard position through the one restart path. The rebuild makes a fresh renderer and synchronizer with the same volume, pitch algorithm and device. Recovery always lands paused, so the user chooses to play on (owner decision). As media3's `pendingRecoverableRendererError` does, it retries once: a second failure before `.playing`, or a rebuild that throws, surfaces as `.failed` with no further rebuild. A media-services reset is a separate event that always rebuilds, since it can follow the failure it caused.

## Alternatives rejected

- `AVAudioEngine`, which is what the apps run today: its clock is nil while paused and leaves output latency to us. Speed needs a time-pitch unit whose buffering the clock cannot see. It is not named for AirPlay 2 enhanced buffering.
- `AVAudioSourceNode` with our own ring buffer: we would own real-time-thread code and estimate latency ourselves, and every route behaviour would be our bug.
- Sonic in-process for speed: a speed change would wait behind the queued audio, and the position map would need a speed checkpoint. The synchronizer rate measured exact.
- One fixed output rate (as Shuttle2 does today): it rules out hi-res and multichannel, and ASBAR took the format change.

## Consequences

- There is no offline render mode, so every rule lives in the Apple-free core. The core is tested against a fake output with a manual clock that can inject an auto-flush, a configuration change or a stall. The ASBAR adapter stays thin and is checked on device.
- `PlaybackRenderTestSupport` ships the fake output, a hand-fired pump and hand-run decode, so an app can drive a `Transport` in its own tests. `AudioOutput`, `PumpTimer`, `SequencerExecutor` and the full `Transport` initialiser are `@_spi(Testing) public`, not public: the production API is unchanged, and only the support target imports the SPI, behind a public `Transport.init(output:timer:executor:onEvent:)` on its fakes. A separate public initialiser would put the seam protocols in the API for every app.
- A route change may auto-flush. The core must re-feed from the flush time, which the sample-accurate seek ([ADR-0009](0009-seeks-are-sample-accurate.md)) allows.
- `audioTimePitchAlgorithm` must be set explicitly, because the iOS default (`lowQualityZeroLatency`) is wrong for speech. The default is `.timeDomain`, for the shorter dropout on a speed change.
- `flush()` and rate changes run off the main thread.
- A format change at a join is audible, which is acceptable because it falls between unrelated tracks. If a gapless album mixes formats, the fix is to keep the earlier format through the join, not to add a mechanism in the feeder.
- Tests to port from media3 and the fixtures are listed in [#93](https://github.com/timusus/AudioPlaybackKit/issues/93#issuecomment-6100145321).
- The probe app and its results are on the `worktree-render-spike` branch (`Spikes/RenderProbeApp`).
  The ASBAR adapter's device checklist still has to cover AirPlay 2 buffer depth and clock
  alignment, Bluetooth, wired headphones, a call and Siri. None of them changes the backend choice.

Links: [#93](https://github.com/timusus/AudioPlaybackKit/issues/93), [ADR-0005](0005-shared-engine-repo.md),
[ADR-0010](0010-the-decoder-owns-output-format-conversion.md).
