# Write an `AudioProcessor`

Code: [`AudioProcessorRecipe.swift`](../../Tests/RecipesTests/AudioProcessorRecipe.swift), four small
processors plus tests that drive them by hand and on a player. They are examples to copy, not API:
effects belong in the app. The rules are in [Usage](../usage.md#play-through-the-render-layer) and
[ADR-0021](../decisions/0021-processor-stream-metadata.md) and
[ADR-0026](../decisions/0026-in-place-processing.md); this page shows the shape.

## The lifecycle

1. `configure(_ input: PCMFormat)` stages the item's format and returns the output format. It applies nothing.
   It can run again mid-item, followed by a drain and a `flush(_:)` for the same item, when the item's
   source changes rate or channel count (a re-opened server stream); derive rate-dependent state there.
2. `flush(_ metadata:)` applies the staged format and starts afresh. It runs before the first frame of every
   item, at every gapless join and after every seek, with `metadata.mediaStartFrame` the frame the
   next audio starts at. **Clear all running state here**; this is how a processor "resets on seek".
3. `process(_:)` (in place) or `queueInput`/`getOutput` (buffering) run per chunk on the transport's
   queue. State the app also touches, such as a gain or a meter reading, needs the processor's own lock.
4. `reset()` flushes and forgets the staged configuration.

Pick the protocol by what happens to frames. Same frames, same channel count: `AudioProcessor`, rewritten
in place. Frames dropped, held back or a different channel count: `BufferingAudioProcessor`. No stage adds
frames, and none can change the sample rate.

## Gain ramp (in place)

Fades in after every flush, so a seek or a new item starts without a click.

```swift
func process(_ samples: UnsafeMutableBufferPointer<Float>) {
    lock.withLock {
        for frame in 0..<samples.count / channels {
            let gain = min(1, Float(framesDone) / Float(rampFrames))
            framesDone += 1
            for channel in 0..<channels { samples[frame * channels + channel] *= gain }
        }
    }
}

func flush(_ metadata: StreamMetadata) {
    lock.withLock { (channels, framesDone) = (stagedChannels, 0) }
}
```

Driven by hand, frames in and out, and a seek restarting the fade:

```swift
var chunk: [Float] = [1, 1, 1, 1, 1, 1]
chunk.withUnsafeMutableBufferPointer { fade.process($0) }
XCTAssertEqual(chunk, [0, 0.25, 0.5, 0.75, 1, 1])

fade.flush(StreamMetadata(item: Track(id: 1), mediaStartFrame: 40))   // a seek
```

## Level meter (in place, read-only)

`LevelMeter` leaves the audio alone and keeps `peak` for the app to poll from a display link. Its `peak`
is read under the lock, because the transport writes it from another queue. Processed audio is heard
about two seconds after it is processed, so a meter leads what is audible by roughly that.

## Mono downmix (buffering, format change)

`configure` returns a different `PCMFormat`, so it is a `BufferingAudioProcessor`:

```swift
downmix.queueInput([1, 3, 2, 4])                     // two stereo frames in
XCTAssertEqual(downmix.getOutput().samples, [2, 3])  // two mono frames out
downmix.queueEndOfStream()
XCTAssertTrue(downmix.isEnded)
```

On a player, the processors run in order and the output gets the final format:

```swift
rig.player.setProcessors([meter, MonoDownmix()])    // the meter hears stereo; the speaker gets mono
XCTAssertEqual(Set(rig.output.enqueues.map(\.format.channelCount)), [1])
```

Adding, removing or reformatting a processor needs another `setProcessors` call; a parameter that changes
inside a stage that stays active applies live.

## Silence trimmer (buffering, dropped frames)

Output plus dropped frames must equal input. Report each dropped run with the output frame it precedes,
so the player's position stays in the file's own media time:

```swift
trimmer.queueInput([0, 0, 0.5, 0.6, 0, 0.7, 0, 0])
XCTAssertEqual(output.samples, [0.5, 0.6, 0.7])
XCTAssertEqual(output.dropped, [
    DroppedFrames(atOutputFrame: 0, inputFrames: 2),
    DroppedFrames(atOutputFrame: 2, inputFrames: 1),
    DroppedFrames(atOutputFrame: 3, inputFrames: 2),
])
```

## Reset on seek, on a player

Every stage is flushed with the landed frame on every seek:

```swift
rig.player.seek(to: 5)
XCTAssertEqual(meter.flushedAt, [0, 40])    // the start, then 5 s at 8 Hz
```
