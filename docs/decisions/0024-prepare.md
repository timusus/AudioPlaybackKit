# ADR-0024: A public `prepare()`, and no auto-skip of a failed item

Status: Accepted
Date: 2026-10-12

## Context

After a failure or `stop()` the player is `.idle` and only `play()` loads again. An app that skips a
failed item while paused (Shuttle2's `onCurrentFailed` policy) could show the next item `.ready` only by
sending the list again with `setItems` (issue #147). media3 has `Player.prepare()` for this.

## Decision

`Player.prepare()` follows media3 `Player.prepare()`: from `.idle` with a current item, stopped or
failed, it clears `error` and loads the current item at `position`, keeping the list and
`playWhenReady`. With `playWhenReady` true it plays, as `play()` would. In any other state, or with an
empty list, it does nothing, as media3's is a no-op unless idle.

There is no opt-in auto-skip of a failed item. media3 has none: `ExoPlayer` stops on any error and apps
call `seekToNext()` and `prepare()` in `onPlayerError`. The policy (how many to skip, when to show an
alert) differs between the apps and already has one home, the `itemFailed` handler.

## Alternatives rejected

- A `skipFailedItems` option: a second mechanism beside `itemFailed`, with a cap and an alert rule
  each app would still need.
- Make `skipToNext()` after a failure load: media3's seeks after an error do not prepare
  (`ExoPlayerTest.seekAfterPlaybackError`), and a skip while paused would then differ from one while idle.

## Consequences

`prepare()` from a failed item opens its source again, so a source that throws at open reports a second
`itemFailed`. `play()` still loads from idle on its own; `prepare()` is needed only to load paused.

Links: ADR-0019, issue #147, `PlayerPrepareTests`.
