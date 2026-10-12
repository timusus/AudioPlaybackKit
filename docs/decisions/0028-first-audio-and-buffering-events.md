# ADR-0028: First-audio and buffering events follow the transport's buffering

Status: Accepted
Date: 2026-10-13

## Context

Podcasts' telemetry needs time to first audio and a stall watchdog (#161, from #139). `Player` had no
signal for either: `state` goes `.buffering` both for the wait after a load or seek and for an underrun,
whatever `playWhenReady` is, and an app sampling it can miss a short stall.

## Decision

Three `PlayerEvent` cases, derived from the transport's `.buffering`/`.playing` status the player already
reads into `state`; no second mechanism.

- **`firstAudioRendered(index:position:)`** is media3 `AnalyticsListener.onRenderedFirstFrame` for audio,
  timed as `onAudioPositionAdvancing`: the first `position` that moves while the transport plays after a
  load, a seek (skips included) or an item transition, gapless or repeat. It covers seeks because
  media3's renderers lower their first-frame state on every position reset, and Podcasts measures seek
  latency as well as start latency. It is not sent on a resume from pause, nor after a stall, whose end
  is `bufferingEnded`. A paused load or seek sends it once played, so the time counts from the call.
- **`bufferingStarted(index:position:)` and `bufferingEnded`** bracket a rebuffer: `state == .buffering`
  with `playWhenReady` set, no suppression, and the current item's first audio already heard. That is
  media3 `STATE_BUFFERING` with play intent minus the join, which PlaybackStatsListener also counts
  apart from rebuffers; `onAudioUnderrun` is its renderer-level twin. Paused there is no event. Every
  start is ended exactly once: by audio resuming, or by a pause, interruption, seek, load, stop or
  failure ending the wait. `bufferingEnded` carries nothing, since an edit or skip may already have
  moved `currentIndex` when it is sent.

Any wait for audio after the first is a rebuffer, not only a network stall: a re-feed after an edit
drops audio decode had queued, and a renderer recovery restarts the output before it lands paused (a
pair closed by that pause).

## Alternatives rejected

- Buffering events for the wait after a load or seek too: it would double-count time to first audio.
- A watchdog timer in the player: a second mechanism over the same status, and the threshold is the app's.

Links: issue #161, `PlayerTelemetryEventTests`, ADR-0019.
