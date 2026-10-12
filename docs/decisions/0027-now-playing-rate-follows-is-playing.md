# ADR-0027: The shown rate follows `isPlaying`, not play intent

Status: Accepted
Date: 2026-10-12

## Context

`NowPlayingSession` writes `MPNowPlayingInfoPropertyPlaybackRate` as `player.isPlaying ? player.rate : 0`,
so the lock screen shows rate 0 while the player buffers with `playWhenReady` true, and its scrubber
stops through a stall. Issue #154 (the rest of #138) asked whether it should follow `playWhenReady`.

## Decision

We keep it. media3's `MediaSessionLegacyStub.createPlaybackStateCompat` reports
`player.isPlaying() && canReadPositions ? speed : 0f` as the session's playback speed, and
`PlaybackStateCompat.STATE_BUFFERING` for a buffering player with play intent. The session therefore shows
rate 0 until audio is heard, and the playing state (`MPNowPlayingPlaybackState.playing`, from
`playWhenReady`) carries the intent, so the play/pause button already shows pause during a stall.

The system extrapolates elapsed time from the rate. A non-zero rate over a stall would run the scrubber
ahead of what is heard, and the correction on resume would be a visible jump back; the same holds for the
late output start (#136).

## Alternatives rejected

- Rate from `playWhenReady`: a scrubber that moves through silence, and a rewrite once audio starts.

Links: issues #154, #138, `NowPlayingInfoTests`.
