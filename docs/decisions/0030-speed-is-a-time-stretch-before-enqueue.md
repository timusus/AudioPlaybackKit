# ADR-0030: Speed is a time-stretch before enqueue

Status: Accepted
Date: 2026-10-20

## Context

[ADR-0018](0018-render-layer.md) set speed as the synchronizer rate. On the iPhone probe each rate change
drops out (97 ms to 2x and 140 ms back with `.timeDomain`) and blocks 41-49 ms, and the renderer's
time-pitch algorithm then runs on every buffer. The Apple units do not fit in-process either: `ipto`
covers only 0.5-2x and holds 1024 frames, `nutp` holds about 93 ms, and `Player.rate` is 0.25...4.
Media3 applies `PlaybackParameters.speed` with `SonicAudioProcessor` before the sink.

## Decision

We will keep the synchronizer at rate 1 while playing (0 paused) and stretch the PCM in the feeder,
after the processors and before enqueue, with a Swift port of the speed path of media3's `Sonic`
(`Sources/PlaybackRender/Sonic.swift`, Apache-2.0, notice kept in the file). At rate 1 the stretch is
bypassed: the chunks are enqueued untouched, with no latency or work added.

- **Changes.** `setRate` re-feeds through `refeedAhead`, the processor-change path: a partial flush at
  the chunk end past `resumeDepth`, or an append when less than `resumeDepth` is written past it.
  Changes while a flush is pending fold into it. So audio queued within half a second of the clock plays
  at the old speed, and nothing else re-renders, stops or rebuffers.
- **The map.** Each segment records the media frames it covers and the `outputFrames` it was written as,
  so its ratio is the speed it plays at and a change mid-item needs no checkpoint. `TimeStretch` keeps
  each tag until Sonic has consumed its frames, then splits Sonic's output among those tags by
  cumulative share, so the spans sum exactly to the samples enqueued.
- **The clock.** The clock is output time. `resumeDepth`, `rebufferDepth` and `maxDepth` are output
  seconds with no rate factor, and seeks, joins, duration and end of stream read through the map as at
  1x. The playhead still adds `outputLatency`.
- **The end.** At the end of upstream, a format change, a seek or a flush, the stretch is flushed or
  reset, so no held frame leaks across a join or a restart.

Deviations from media3: Float samples, where media3 runs on 16-bit shorts, so the period search
averages floats; only the speed path is ported (no pitch or resampling rate). The port keeps media3's
accumulated speed-adjustment error, without which the whole-frame period counts drift (8.67 media
seconds in 2 s at 4x).

## Alternatives rejected

- The synchronizer rate, as in ADR-0018: an audible dropout and a blocking call on every change.
- `AVAudioUnitTimePitch` (`nutp`) or `ipto` offline: about 93 ms or 1024 frames of latency, and `ipto`
  stops at 2x.
- Flushing everything queued on a change: a rebuffer and a gap, where the partial flush has neither.

## Consequences

- A speed change is heard about `resumeDepth` plus a chunk late, as an effect change is.
- Sonic runs on the transport's queue up to 30 s ahead of the speaker, never on the render thread. Its
  cost is a pitch-period search per period, as on Android; nothing is added at 1x.
- Sonic holds up to two pitch periods (about 30 ms) before it outputs, so a restart at a rate other
  than 1 takes a little longer to reach `resumeDepth`.
- `Transport.init(timePitchAlgorithm:onEvent:)` and `Player`'s `timePitchAlgorithm:` are gone (0.17.0):
  the renderer no longer changes speed.
- Stretched output is not bit-identical to the source; rate 1 is.

Links: [ADR-0018](0018-render-layer.md), [ADR-0026](0026-in-place-processing.md), [usage](../usage.md),
media3 `Sonic`, `SonicAudioProcessor`.
