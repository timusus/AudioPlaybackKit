# ADR-0026: Processors that keep every frame run in place

Status: Accepted
Date: 2026-10-12

## Context

`AudioProcessor` took each chunk as `[Float]` and handed it back through `getOutput()`, so every stage
copied and allocated per chunk; Shuttle2's EQ and limiter made two copies (#149). Most stages (EQ,
ReplayGain, Voice Boost, a limiter without lookahead) keep every frame where it is. Media3's
`AudioProcessor` has one shape, `queueInput(ByteBuffer)` then `getOutput()`; `BaseAudioProcessor`
avoids the allocation by reusing its output buffer (`replaceOutputBuffer`), but still copies.

## Decision

`AudioProcessor` is the in-place shape: `process(_ samples: UnsafeMutableBufferPointer<Float>)` rewrites
the chunk's own samples, and the pipeline keeps its tags. `BufferingAudioProcessor: AudioProcessor`
keeps the queue shape (`queueInput`, `getOutput`, `queueEndOfStream`, `isEnded`) for a stage that drops
or holds back frames or changes the channel count; its `process` has a trapping default the pipeline
never calls. The pipeline takes chunks `consuming`, so an in-place chain neither copies nor allocates.

`configure`, `flush` and `reset` run once per item, seek or chain change and may allocate; `process`
and `queueInput` run per chunk and should not. All of them run on the transport's queue, not the
render thread, about two seconds ahead of the speaker.

Deviations from media3:

- An in-place path at all: media3 copies input into the processor's output buffer at every stage. A
  borrowed Swift buffer costs nothing, and a 1:1 stage then needs no output state.
- The queue shape keeps `[Float]` and `ProcessorOutput`, not a reused output buffer: only skip-silence
  and lookahead limiters use it, and a borrowed `getOutput` buffer would put lifetime rules on apps.
- An in-place stage cannot change the format; media3's `ChannelMappingAudioProcessor` is a buffering
  stage here.

## Alternatives rejected

- One protocol with both shapes and defaults: a conformer could implement neither (ADR-0021), and an
  in-place default for the queue needs storage a protocol extension does not have.
- `inout [Float]`: a stage could resize or replace the array, which allocates and breaks the tags.
- Media3's reused output buffer for every stage: still one copy per stage, and unsafe lifetimes on the
  queue path for every app processor.

## Consequences

- A source break for every conformer (0.11.0, with ADR-0021): a 1:1 stage moves to `process(_:)`, the
  rest add `BufferingAudioProcessor`.
- A lookahead limiter delays audio, so it is buffering; run in place it would shift the tags and lose
  its tail at the end of an item.
- A wrapper must keep its base's shape; the player's keyed wrapper picks one of two classes.
- `AudioProcessingPipelineTests.testInPlaceStagesRewriteTheInputBufferItself` proves no copy by buffer
  identity.

Links: [ADR-0018](0018-render-layer.md), [ADR-0021](0021-processor-stream-metadata.md),
[usage](../usage.md), [migrating](../migrating.md), issue #149, media3 `AudioProcessor`,
`BaseAudioProcessor`.
