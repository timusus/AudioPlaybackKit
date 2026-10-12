# ADR-0020: Now Playing drives a protocol, not the concrete `Player`

Status: Accepted
Date: 2026-10-12

## Context

Shuttle2 routes every lock-screen and remote command through its own policy (queue rules, a skip
increment per item; timusus/Shuttle2#1020, #141). `NowPlayingSession` called `Player` directly, with one
`skipMode` for every item. media3 1.11.1 deprecates the per-command hook
`MediaSession.Callback.onPlayerCommandRequest`: a session drives a wrapping player (`ForwardingPlayer`),
and the wrapper's `Player.Commands` decide what controllers are offered.

## Decision

We will have `NowPlayingSession` drive `NowPlayingControllable` (in `PlaybackPlayer`): the state it
shows, the commands it sends, `availableCommands: PlayerCommands` (media3 `Player.Commands`) and
`skipIntervals`, which only adds the skip buttons beside next and previous. `Player` conforms; an app wraps it through
`ForwardingNowPlayingControllable`, which forwards every requirement the wrapper does not declare.

## Alternatives rejected

- A per-command `onCommand -> .handled/.useDefault` callback: the shape media3 deprecated, and it
  cannot grey a command out.
- An open `ForwardingPlayer` class: a protocol whose extension forwards to `player` is the same with
  no subclassing, and lets the wrapper be `@Observable`.
- A `commandsChanged` listener, as media3's `onAvailableCommandsChanged`: the session already reads the
  player under Observation, so an `@Observable` wrapper's changes re-evaluate it with no extra API.
- Increments on `Player`, as media3's `getSeekForwardIncrement`: iOS draws either skip buttons or next
  and previous, so the choice is presentation, and per item; it belongs to the wrapper.

## Consequences

- `skipMode` is gone. A spoken-word app declares `skipIntervals` on a five-line wrapper; per-item
  intervals and commands are re-read on every item change and every change the wrapper makes.
- A command absent from `availableCommands` is disabled on `MPRemoteCommandCenter`, and a press that
  races the change is refused with `.commandFailed`, as media3 refuses an unavailable command.
- The previous button is `seekToPrevious()` (media3 `seekToPrevious`, which restarts an item with
  nothing before it) and next is `seekToNext()`, so `Player.skipToPrevious` keeps its item-only meaning.
- A wrapper's own state must be `@Observable`, or the session misses its changes until the player's
  next change.

Links: [ADR-0019](0019-player.md), [usage](../usage.md#show-a-player-on-the-lock-screen), #141.
