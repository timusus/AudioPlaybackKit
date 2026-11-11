# ADR-0030: Speed is a time-stretch before enqueue

Status: Accepted
Date: 2026-10-20

## Context

[ADR-0018](0018-render-layer.md) set speed as the synchronizer rate. On the iPhone probe each rate change
drops out (97 ms to 2x and 140 ms back with `.timeDomain`) and blocks 41-49 ms, and the renderer's
time-pitch algorithm then runs on every buffer. `Player.rate` is 0.25...4.

## Decision

We will keep the synchronizer at rate 1 while playing (0 paused) and stretch the PCM in the feeder,
after the processors and before enqueue, with Apple's `AUNewTimePitch` (`nutp`) run through the v2
render-callback API. At rate 1 the stretch is bypassed: the chunks are enqueued untouched, with no
latency or work added. Apple's units are not limited to 0.5-2x: `nutp` and `ipto` both work at 3x and
beyond, so the 0.25...4 range is covered.

- **Changes.** `setRate` re-feeds through `refeedAhead`, the processor-change path: a partial flush at
  the chunk end past `resumeDepth`, or an append when less than `resumeDepth` is written past it.
  Changes while a flush is pending fold into it. So audio queued within half a second of the clock plays
  at the old speed, and nothing else re-renders, stops or rebuffers.
- **The map.** Each segment records the media frames it covers and the `outputFrames` it was written as,
  so its ratio is the speed it plays at and a change mid-item needs no checkpoint. `TimeStretch` keeps
  each tag until the unit has consumed its frames, then splits the unit's output among those tags by
  cumulative share, so the spans sum exactly to the samples enqueued.
- **The clock.** The clock is output time. `resumeDepth`, `rebufferDepth` and `maxDepth` are output
  seconds with no rate factor, and seeks, joins, duration and end of stream read through the map as at
  1x. The playhead still adds `outputLatency`.
- **The pull.** Each render pulls exactly `rate x frames` of input, so input consumption is exact and the
  map needs no estimate.
- **Delay compensation.** The unit's output lags its input by one window of input frames plus one of output
  frames (window + window/rate output frames in all). The window is 32 ms rounded up to a power of two,
  at most 4096 frames: 2048 at 44.1 and 48 kHz, 1024 at 22.05 kHz. `TimeStretch` cuts that lead from the start of the item and
  renders it out at the end, so the first sample out is the first of the source and the last frame of the
  item is heard.
- **Fresh units.** A re-feed builds a fresh unit, which fades in over 5-20 ms. That is the price of a
  change, heard once at the change.
- **The end.** At the end of upstream, a format change, a seek or a flush, the stretch is flushed or
  reset, so no held frame leaks across a join or a restart.
- **The seam.** `StretchUnit` is the protocol over the unit. A whole-sample fake keeps the tests whose
  sample values name their frame; `TimeStretchTests` runs the real unit for quality.
- **Placement.** A processor runs before the stretch by default (`AudioProcessorPlacement.beforeTimeStretch`),
  in media time, so it is sped up with the programme: use it for anything that shapes the content, such
  as skip-silence or Voice Boost. One marked `.afterTimeStretch` runs on the stretch's output, in output
  time at the output format, as media3 apps append a processor after Sonic: use it for what the listener
  must hear at a fixed length and level whatever the speed, such as a cue mixed in. It must be in place
  (no buffering, no format change), so spans, the map and gapless boundaries are untouched; it is
  flushed at each item's first output frame, in output frames from there (at a rate other than 1 they
  do not advance `mediaStartFrame` one for one), and reset at every seek, stop, renderer recovery and
  chain replacement. `setProcessors` with the same post-stretch instances in the same order (say, only a
  pre-stretch stage changed) replaces nothing: they are configured again, and only a change in which of
  them are active flushes them again at the re-fed frame. At a re-feed (a speed change, `processorsChanged`, or such a
  `setProcessors`) each is asked to step back over the output frames dropped
  (`rewind(outputFrames:)`), so a cue cut mid-way resumes where it was cut; one that declines, or a
  drop reaching back past its last flush, is reset and flushed at the re-fed frame as at a seek. Audio
  replayed after a stall is not processed again.

## Alternatives rejected

- The synchronizer rate, as in ADR-0018: an audible dropout and a blocking call on every change.
- Sonic (a port of the speed path of a pitch-period stretch, as in Android's media3 `SonicAudioProcessor`):
  it smears polyphonic music from 1.5x up. A chord's common period (about 55 Hz) is below its 65 Hz
  minimum pitch period, so no single period fits. The port is not at fault: chunked output was
  bit-identical to one whole-buffer call. Log-spectral distance from the source at 1.25/1.5/2/3x:

  | Material | Sonic | AUNewTimePitch |
  |---|---|---|
  | Grieg | .48/.81/1.29/2.00 | .30/.41/.60/.89 |
  | rock | .31/.44/.66/.79 | .21/.27/.35/.47 |
  | speech | .89/1.15/1.61/1.95 | .82/.78/.91/1.12 |

  A synthetic chord's SNR is 4-10 dB with Sonic and 46-54 dB with AUNewTimePitch.
- `AVAudioUnitTimePitch` in an engine, or `ipto` offline: both need an engine or a second clock, where
  the render-callback unit runs inside the feeder.
- Flushing everything queued on a change: a rebuffer and a gap, where the partial flush has neither.

## Consequences

- A speed change is heard about `resumeDepth` plus a chunk late, as an effect change is.
- The unit runs on the transport's queue up to 30 s ahead of the speaker, never on the render thread;
  nothing is added at 1x.
- The unit's lead (window + window/rate output frames) delays the first stretched output, so a restart at a
  rate other than 1 takes a little longer to reach `resumeDepth`.
- `Transport.init(timePitchAlgorithm:onEvent:)` and `Player`'s `timePitchAlgorithm:` are gone (0.17.0):
  the renderer no longer changes speed.
- Stretched output is not bit-identical to the source; rate 1 is.

Links: [ADR-0018](0018-render-layer.md), [ADR-0026](0026-in-place-processing.md), [usage](../usage.md).
