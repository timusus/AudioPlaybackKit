# ADR-0031: Position is read on demand; observers replace the cadence

Status: Accepted
Date: 2026-10-23

## Context

The transport pumped every 100 ms while playing only to push `.position` (#189): about ten wakeups a
second for a value most readers want a few times a second or only at a time T. `.seekLanded`,
`.firstAudioRendered` and the `.positionDiscontinuity` pairing rode on that push.

## Decision

Position is computed when read, as media3 `Player.getCurrentPosition` and AVPlayer `currentTime()`.
The 100 ms cadence and `TransportEvent.position` are gone.

- **Snapshot.** After every queue entry (a call or a pump) the transport publishes, under its lock, a copy
  of the position map, the restart frame used before audio is written, the feeder's monotonic floor and the
  number of calls taken. `Transport.position` maps the output clock through that copy on the caller's
  thread, with no hop to the queue. A main-actor read costs a lock and a clock read.
- **Monotonic, paired with discontinuities.** The read returns nil while a `setCurrent` or `seek` is called but not taken,
  as `.position` was dropped before. Within one item and one taken call it never goes back: it is floored at the feeder's last
  reported position and at the last value read. A clock that steps back on a re-anchor or a latency change does not move it. `Player.position` reads the
  transport only once every call is answered and the item heard is the current one. Until then it
  returns the value set with the last `discontinuityCount` change, so a reader never pairs a new count with an old position.
- **Events that rode on `.position`** each get their own trigger:
  - `.landed(item:seconds:)` is the first position of a `setCurrent` or `seek`, once its first audio is
    written. The player sends `seekLanded` and `seekAdjusted` from it.
  - `.durationChanged(item:duration:isSeekable:)` is sent when the heard item's duration or seekability
    differs from what was last sent: on landing, at a crossing, or when the source learns it.
  - `firstAudioRendered` is sent on `.status(.playing)` after a landing, or on a landing or `.crossed`
    while already playing. This is the audio starting, not media3's `onAudioPositionAdvancing` (the
    first position that moves), which would need a deadline of its own. On a real output the two are a
    frame apart.
- **Observers**, named as AVPlayer's:
  - `addPeriodicObserver(interval:using:)` (`addPeriodicTimeObserver`) fires every `interval` of output
    time while playing. It arms a deadline only while registered. The interval is output time, not item
    time as in AVPlayer: at 2x speed it fires at the same wall rate, so wakeups never double.
  - `addBoundaryObserver(times:using:)` (`addBoundaryTimeObserver`; media3's equivalent is
    `PlayerMessage.setPosition`) fires once when playback crosses a time in the heard item, at a deadline
    the map computes. A seek or load landing past a time does not fire it.
  - Both return a token that removes the observer on `cancel()` or deinit. Transport callbacks run on
    its queue and player callbacks on the main actor.

While playing with no observers, the pump wakes only for:

- the refill, every `resumeDepth` (0.5 s) while the 30 s cap is written, or the renderer's ready event
  when it holds less;
- item and format boundaries;
- the end of what is written;
- decode and output wakes.

## Alternatives rejected

- A slower cadence: it still wakes for nobody, and every observer's wakeup would still be late by up to the cadence.
- Pushing the position from a `CADisplayLink`: that is UI. The app's periodic observer does this.
- Hopping to the queue for each read: a main-actor read would block behind a 75 ms flush.

## Consequences

`Player.position` is no longer observable by SwiftUI between discontinuities. A progress bar
subscribes with `addPeriodicObserver` and reads `position` on each fire. Ad and silence skips and the
sleep timer use `addBoundaryObserver`.

Release note (minor bump): `TransportEvent.position` is removed, replaced by `.landed` and
`.durationChanged`. `Transport.position`, `Transport` and `Player` `addPeriodicObserver(interval:using:)`
and `addBoundaryObserver(times:using:)` are added. `Player.position` is computed on read.

Links: #189, ADR-0018 (pump scheduling), ADR-0019, ADR-0028.
