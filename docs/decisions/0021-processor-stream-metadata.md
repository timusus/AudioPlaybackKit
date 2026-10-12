# ADR-0021: A processor's flush names the item that follows

Status: Accepted
Date: 2026-10-12

## Context

Some processors depend on the item: ReplayGain needs the track's gain. A `flush()` with no argument
left a processor unable to tell which item its frames belong to, and a same-format gapless join did not
flush at all, so audio of two items ran through one stream. Media3 1.11.0 added
`AudioProcessor.StreamMetadata` (timeline, period uid, position offset) passed to
`flush(StreamMetadata)` (androidx/media#418). `DefaultAudioSink` drains its processors when the next
period's configuration is pending, then `setupAudioProcessors` flushes them with that metadata.

## Decision

`AudioProcessor.flush(_ metadata: StreamMetadata)` replaces `flush()`. `StreamMetadata` carries the
item (the app's `Item` given to `Transport` or `Player`, as `any Hashable & Sendable`) and
`mediaStartFrame`, the item's media frame of the first frame after the flush. The pipeline is drained
and flushed at every item change, gapless joins included, at the first item's start and after each
seek, so a flush is always followed by frames of one item only.

Deviations from media3:

- The item, not a timeline and period uid: APK has no timeline, and the app's own item is what a
  processor looks up a gain by. `Player` maps its private transport keys back to the app's item.
- `mediaStartFrame` instead of `positionOffsetUs`: positions below `Transport` are frames at the item's
  own rate, and an item's frames are what a processor counts.
- No deprecated `flush()` kept beside it: two requirements, one defaulting to the other, let a
  conformer implement neither by mistake. A processor that needs no metadata ignores the argument.

## Alternatives rejected

- Wrapping the item source to apply ReplayGain before the chain: it works only for gain, and the
  processor order (gain before EQ and limiter) then lives outside `setProcessors`.
- Tagging every chunk with its item for the processor: chunks may straddle items inside a stage that
  holds audio back, and media3's model is per stream.

## Consequences

- A source break for every conformer (a minor bump at 0.x).
- Filter memory and a limiter's envelope reset at every join, as they did only at a format change. A
  stage holding audio back drains it at the join, so nothing is lost or repeated.
- A drain processes no extra frames; it only hands over at the join what a stage held back.

Links: [ADR-0018](0018-render-layer.md), [usage](../usage.md), issue #143,
[androidx/media#418](https://github.com/androidx/media/issues/418).
