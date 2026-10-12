# ADR-0023: Pause at end stays on the finished item

Status: Accepted, amends ADR-0019
Date: 2026-10-12

## Context

`pauseAtEndOfItem` moved to the next item and paused it at 0, a deliberate departure from media3 in
ADR-0019. Shuttle2's sleep timer ("stop at end of track") and its lock screen expect the finished item
to stay shown, as media3's `pauseAtEndOfMediaItems` leaves it (issue #148). The only signal was
`playWhenReadyChanged(false, reason: .endOfItem)`, undocumented as the one to key on.

## Decision

We match media3 (`ExoPlayerTest.pauseAtEndOfMediaItems_pausesPlaybackBeforeTransitioningToTheNextItem`):
at the end of an item the player sets `playWhenReady` false, sends
`playWhenReadyChanged(false, reason: .endOfItem)` (media3 `PLAY_WHEN_READY_CHANGE_REASON_END_OF_MEDIA_ITEM`),
and stays on the item, `.ready` with `position` at its duration. `play()` makes the next current with
`itemTransition(.auto)` (`.repeat` under `.one`) and loads it; with nothing following it restarts the
item, as from `.ended`. A seek stays on the item. The last item still ends. `playWhenReadyChanged` with
`.endOfItem` is the one event apps key on.

Set after decode has passed into the next (its last seconds), media3 flushes back to the current item
(`setPauseAtEndOfWindowInternal` seeks to the current position). The transport cannot unhear the join,
so the player does not take the crossing: it pauses and stays on the finished item, and `play()` loads
the next afresh. Up to one pump (100 ms) of the next may be heard first.

## Alternatives rejected

- Keep landing on the next, behind an option: two behaviours for one concern, and the apps want media3's.
- Flush in the transport when `clearNext` finds the next already decoded: a render-layer change for a
  rare race, and a `setNext` queued behind a decoded next would still cross.

## Consequences

`play()` after a pause at end opens the next item's source then, not ahead (nothing is armed under
pause at end, as before), so it starts after a load rather than gaplessly. Every exit from the pause
is a load or unload, which keeps the state machine to one flag (`pausedAtEnd`).

Links: ADR-0019, issue #148, `PlayerAdvanceTests`.
