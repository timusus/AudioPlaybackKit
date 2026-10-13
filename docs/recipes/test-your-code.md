# Test your code with the fakes

Code: [`TestAppCodeRecipe.swift`](../../Tests/RecipesTests/TestAppCodeRecipe.swift). Add
`PlaybackPlayerTestSupport` and `PlaybackRenderTestSupport` to your test target, never your app target.

`PlayerTestRig` is a real `Player` on a fake speaker, a fake `AVAudioSession` and a clock the test turns,
so tests run in milliseconds and cannot flake. `FakeItemFactory` makes items that play, fail or end
early on a script. Your coordinator is the code under test:

```swift
let rig = PlayerTestRig<Track> { try factory.make($0) }
let coordinator = PlaybackCoordinator(player: rig.player)
rig.player.setItems([Track(id: 1)])

coordinator.togglePlayPause()
rig.run(for: 1)                                  // plays one second of fake time
XCTAssertTrue(rig.player.isPlaying)
XCTAssertEqual(rig.session.activations, 1)
```

| To simulate | Use |
|---|---|
| Time passing | `rig.run(for:)`; `rig.settle()` to deliver calls without time |
| A phone call | `rig.session.interruptionBegan()` / `interruptionEnded(shouldResume:)` |
| An item that cannot open | `factory.unopenable = [item]` |
| A drop halfway through | `factory.failingAtFrame = [item: 40]` |
| A truncated file | `factory.endingAtFrame`; a live stream: `factory.live` |
| A seek the source cannot honour | `factory.failingSeeks`, `coarseSeeks`, `unseekable` |
| What the speaker got | `rig.output.enqueues`, `rig.output.played` |
| Events as they happen | `rig.onEvent = { ... }` |

A failure example, end to end:

```swift
factory.unopenable = [Track(id: 2)]
rig.player.setItems([Track(id: 1), Track(id: 2), Track(id: 3)])
rig.player.play()
rig.run(for: 11)
XCTAssertEqual(rig.player.error?.kind, .source)

coordinator.skipFailedItem()                     // skipToNext(), then play()
rig.run(for: 2)
XCTAssertEqual(rig.player.currentItem, Track(id: 3))
```

For code on `Transport` directly use `PlaybackRenderTestSupport` (`FakeAudioOutput`, `ManualPumpTimer`,
`ManualExecutor`, `FakeItemSource`); for streaming code use `LoopbackMediaServer`
(see [Stream a URL](stream-a-url.md)). The fakes for the lock screen are in
[Lock screen](lock-screen.md).
