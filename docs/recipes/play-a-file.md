# Play a file

Code: [`PlayAFileRecipe.swift`](../../Tests/RecipesTests/PlayAFileRecipe.swift).

## PCM only

Link `PlaybackDecode`. `open()` and `nextChunk()` block, so run them on a thread of your own.

```swift
let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
let format = try decoder.open()

var frames = 0
while let chunk = decoder.nextChunk() {
    frames += chunk.count / format.channelCount
}
// A nil chunk is only the end of the file when `endReason` says so.
XCTAssertEqual(decoder.endReason, .eof)
```

Chunks are interleaved Float32 at `format.sampleRate`; hand them to your own renderer.

## Play it

Link `PlaybackPlayer` and `PlaybackRender`. The app passes only `makeSource`; the test rig swaps the
speaker and clock for fakes so three seconds play instantly.

```swift
let rig = PlayerTestRig<URL> { FFmpegItemSource(reader: try FileByteReader(url: $0)) }
let player = rig.player!

player.setItems([url])
player.play()
rig.run(for: 1)

XCTAssertTrue(player.isPlaying)
XCTAssertEqual(player.duration ?? 0, 3, accuracy: 0.01)
```

In the app: `Player<URL>(makeSource: { FFmpegItemSource(reader: try FileByteReader(url: $0)) })`, then
`setItems` and `play()`. The session is activated on the first `play()`. Read `state`, `position` and
`duration` from the `@Observable` player.
