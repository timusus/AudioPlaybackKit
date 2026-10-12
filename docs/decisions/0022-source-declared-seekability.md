# ADR-0022: Sources declare seekability; a seekable item of unknown length is not live

Status: Accepted, amends ADR-0017
Date: 2026-10-12

## Context

The player called an item live whenever its source reported no duration, so it refused to seek and
greyed out the scrubber. A server transcode that streams progressively with no length but re-opens
at a time offset seeks fine, and was shown as live (issue #142). A seek the source could not make as
asked (past the end, on a live item, landing on a keyframe before the target) moved `position`
without saying so, or failed the item.

media3 keeps the two apart: `Timeline.Window` has `isSeekable` and `durationUs`, and `isLive` is a
third fact. `COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM` follows `isSeekable`. A seek that lands somewhere
other than asked is reported as `DISCONTINUITY_REASON_SEEK_ADJUSTMENT`.

## Decision

`ItemSource.isSeekable` is read once `open()` returns, like `duration`; it defaults to a known
duration. `FFmpegItemSource` is seekable when the container has a duration or the byte source a
length, ADR-0017's rule. Transport carries it on each `.position` event.

The player derives `isLive` as neither seekable nor of known duration, and exposes `isSeekable`.
`availableCommands` offers seek-in-item, seek forward and seek back from `isSeekable` alone.

A seek is never dropped silently and never fails the item for being unseekable. `PlayerEvent.seekAdjusted(index:requested:position:)`
reports it:
- at the call, for a target clamped to `0...duration`;
- at the call, for a seek refused by an item known to be unseekable, which stays where it is;
- after `seekLanded`, when the source lands more than 1 ms from the target. This also moves
  `discontinuityCount`.

## Alternatives rejected

- An explicit `isLive` on `ItemSource`: live is what a source neither seeks nor knows the end of; a
  third flag could contradict the other two.
- Fold the adjustment into `seekLanded`: an app that saves the landing would have to compare it to its
  own request. media3 sends the adjustment as its own discontinuity.
- Seek an unseekable progressive item to 0, as media3's `SeekMap.Unseekable` does: a scrub on a live
  stream would restart nothing and lose the listener's place in a known-length one, so it stays put.
- An exact landing check: frame rounding moves a landing by under 1 ms at any real sample rate, which
  is not an adjustment.

## Consequences

- A seek made before a live item opens still reaches its source, which throws `unseekable` and fails
  the item. The player cannot know before the open; skipping the seek belongs in `Sequencer`.
- A seek during the open of a seekable item of unknown length is not clamped at its end; the source
  decides where it lands, and an adjustment is reported if it differs.
- `NowPlayingSession` shows such an item as not live, with the metadata's duration if any, and
  enables the scrubber.

Links: [ADR-0017](0017-live-streams.md), [ADR-0019](0019-player.md),
[ADR-0020](0020-now-playing-drives-a-protocol.md), issue #142, media3 `Timeline.Window.isSeekable`,
`Player.DISCONTINUITY_REASON_SEEK_ADJUSTMENT`, `COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM`.
