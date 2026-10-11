---
paths:
  - "Tests/PlaybackRenderTests/**"
---

# Render tests on the real output

- `SampleBufferAudioOutputIntegrationTests` plays through the Mac's default output in wall time.
  The position rate, the order of events and the end frame are always checked: they hold under load.
- How late `.ended` arrives is not: macOS coalesces the pump timer, a synchronizer rate change
  blocks, and a loaded machine adds seconds. Those upper bounds run only with
  `RENDER_EVENT_BOUNDS=1 swift test --filter SampleBufferAudioOutputIntegrationTests`, on an idle
  Mac, after a change to the feeder, the pump or the output.
