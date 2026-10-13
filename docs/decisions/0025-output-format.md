# ADR-0025: The player reports the format its processors run at

Status: Accepted
Date: 2026-10-12

## Context

A processor learns its format in `configure(_:)`, but an app's UI cannot. Shuttle2's EQ screen draws
its response curve at the rate the filters run at and falls back to 48 kHz without it (issue #150).
media3 has `Player.getAudioFormat()` and `AnalyticsListener.onAudioInputFormatChanged`.

## Decision

`Player.audioFormat: PCMFormat?` is the current item's decoded format, the one the processor chain is
configured with for it (`SequencedUpstream` configures the pipeline at each decoded chunk's format, and
the decoder keeps one format per item, ADR-0010). Processors cannot resample, so its rate is also the
output's. It is observable like `duration` and has the same lifecycle: nil after a load, skip or
crossing until the item's audio is heard, and kept through pause, stop and failure.

The transport carries it on `TransportEvent.crossed(item:format:)`, read from the format the item's
first chunk was pulled at. The player takes it only for the item it makes current, so a next item
decoded ahead, or a join heard under pause at end (ADR-0023), leaves it on the finished item.

The name follows media3 rather than the issue's `outputFormat`: it is the format into the processors,
which is media3's audio input format, and a chain could change the channel count on the way out.

## Alternatives rejected

- Report it when the pipeline is configured, as media3's renderer-input callback does: that is about two
  seconds ahead of the playhead, so the EQ screen would show the next item's rate while the current
  one plays.
- A separate `TransportEvent` case: the format changes only at a crossing, so a second event would
  always travel with `.crossed`.
- A per-event `PlayerEvent`: `audioFormat` is state, observed like `duration`; no app needs the edge.

## Consequences

`TransportEvent.crossed` gains a payload, a source break for an app matching `.crossed(let item)`
(it becomes `.crossed(let item, _)`). A format change inside one item (`ItemSource.currentFormat`, a
re-opened server stream, #179) reconfigures the processors but is not reported here.

Links: ADR-0010, ADR-0018, ADR-0023, issue #150, `PlayerAudioFormatTests`.
