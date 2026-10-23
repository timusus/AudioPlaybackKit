# Queue, seek and progress

Code: [`GaplessQueueRecipe.swift`](../../Tests/RecipesTests/GaplessQueueRecipe.swift) and
[`SeekAndProgressRecipe.swift`](../../Tests/RecipesTests/SeekAndProgressRecipe.swift). The examples use
`FakeItemFactory` (ten seconds per item at 8 Hz) so they run on a manual clock.

## A gapless queue

The player arms the next item itself, so the app hands over the list and listens for transitions. Each
event carries the item it names as well as its index, so read `to?.item`, not `player.items[to.index]`:
the list may have changed by the time `events` yields it.

```swift
rig.onEvent = {
    if case let .itemTransition(_, to, reason) = $0 { transitions.append((to?.item, reason)) }
}
rig.player.setItems([Track(id: 1), Track(id: 2), Track(id: 3)])
rig.player.play()
rig.run(for: 31)

XCTAssertEqual(transitions.map(\.to), [Track(id: 2), Track(id: 3)])
XCTAssertEqual(transitions.map(\.reason), [.auto, .auto])
// Heard audio is one run: a join that left a hole would play silence between the items.
```

Items of different sample rates join in the same stream (`testItemsAtDifferentSampleRatesJoinGaplessly`).
When the queue changes while playing (shuffle, add, remove), call `replaceItems`, or the player keeps a
stale next item armed:

```swift
rig.player.replaceItems([Track(id: 1), Track(id: 3)], currentIndex: 0)
```

## Seeking and progress

`duration`, `state` and `isSeekable` are observable on the main actor. `position` is read from the clock,
so a slider reads it from `addPeriodicObserver(interval:using:)` (see `docs/usage.md`).
`seek(to:)` and `seek(by:)` act on the current item and clamp to it; `seek(to:itemAt:)` crosses items.

```swift
rig.player.seek(to: 6)
rig.run(for: 1)
XCTAssertEqual(landed.map(\.position), [6])           // from .seekLanded

rig.player.seek(by: -100)                              // clamped to the start
rig.player.seek(to: 4, itemAt: 1)                      // across items
```

A source may land elsewhere than asked (a keyframe, a VBR MP3). `position` is where it did land, and
`.seekAdjusted(requested:position:)` says so:

```swift
factory.coarseSeeks = [Track(id: 1)]
rig.player.seek(to: 5.5)
XCTAssertEqual(adjusted.map(\.position), [5])
```

A live or unseekable item refuses a seek and keeps playing from where it is: disable the slider from
`isSeekable`.

The decoder alone behaves the same way: use what `seek(toSeconds:)` returns, not the target.

```swift
let landed = try decoder.seek(toSeconds: 2.5)
```
