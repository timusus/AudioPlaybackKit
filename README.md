# AudioPlaybackKit

![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![Platforms](https://img.shields.io/badge/platforms-iOS%2017%20%7C%20macOS%2014-blue)
![SwiftPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen)
![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey)

Play the audio AVPlayer won't, and own the PCM on the way out. A Swift package over FFmpeg for iOS and macOS,
used in production by Shuttle Podcasts and Shuttle2.

What an app gets:

- **Formats AVPlayer lacks.** Ogg Vorbis, Ogg Opus, FLAC in Ogg and Matroska/WebM audio, alongside MP3, AAC, M4A/ALAC, FLAC and WAV/AIFF.
- **Playback before the download ends.** `GrowingFileByteSource` reads an HTTP(S) URL while it downloads, with range-request resume, stall detection and retry. An MP4 with its index at the end plays from range requests.
- **Seeks that land on the sample** (VBR MP3 excepted), gapless joins between items (even at different sample rates), and decode that can be cancelled while blocked on the network.
- **A decoder checked against goldens.** Over a hundred fixtures run through a faulting reader and a seek matrix against committed PCM hashes, modelled on androidx/media's tests ([ADR-0008](docs/decisions/0008-conformance-testing-modelled-on-media3.md)).
- **An output layer to replace your `AVAudioEngine` graph** (`PlaybackRender`). One `Transport` drives an `AVSampleBufferAudioRenderer` and its synchronizer: play, pause, seek, speed, a gapless next item, and your effects as `AudioProcessor`s. Position comes back as the frame being heard. A failed renderer or a media-services reset is recovered once, landing paused where it was ([ADR-0018](docs/decisions/0018-render-layer.md)).
- **Testable seams.** Bytes come from a `StreamByteReader`, items from an `ItemSource`, effects are `AudioProcessor`s, and `LoopbackMediaServer` is a fault-injecting local server for your own streaming tests.
- **LGPL done for you.** FFmpeg ships as a dynamic framework Xcode embeds without a build-phase change, so users can relink ([ADR-0001](docs/decisions/0001-ffmpeg-for-demux-and-decode.md)).

## What's inside

Link only the products you import.

| Product | What it is |
|---|---|
| `PlaybackDecode` | `FFmpegStreamDecoder`: interleaved Float32 PCM from any `StreamByteReader`; `FileByteReader` reads a local file. |
| `PlaybackStreaming` | `GrowingFileByteSource`: plays an HTTP(S) URL while it downloads. |
| `PlaybackRender` | `Transport`: plays decoded PCM through `AVSampleBufferAudioRenderer`, joining items gaplessly. |
| `PlaybackRenderTestSupport` | `FakeAudioOutput`, `ManualPumpTimer`, `ManualExecutor` and `FakeItemSource`: a `Transport` driven deterministically from tests. |
| `PlaybackPlayer` | `Player`: the item list, play intent and state, position and duration in seconds, seek across items, and the audio session. |
| `PlaybackNowPlaying` | `NowPlayingSession`: a `Player` on the lock screen, Control Centre and CarPlay, with the remote commands routed back to it. |
| `PlaybackStreamingTestSupport` | `LoopbackMediaServer`: a local HTTP server for testing code that streams. |
| `PlaybackPlayerTestSupport` | `FakeAudioSession` and `PlayerTestRig`: a `Player` on a fake output and manual clock, for testing an app's coordinator. |
| `FFmpeg` | The LGPL-only FFmpeg as a dynamic framework, for an app with its own C code against libavformat. |

## Install

```swift
.package(url: "https://github.com/timusus/AudioPlaybackKit.git", from: "0.9.0")
```

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "PlaybackDecode", package: "AudioPlaybackKit"),
    .product(name: "PlaybackStreaming", package: "AudioPlaybackKit"),   // only to play URLs
])
```

Requires iOS 17 or macOS 14, Apple silicon. Pin a tag, never a branch. The API may change before 1.0; a public API change is a minor version bump until then.

## Example

```swift
import PlaybackDecode

let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: fileURL))
let format = try decoder.open()                  // sample rate, channel count, duration

while let chunk = decoder.nextChunk() {          // interleaved Float32, up to 4096 frames
    // hand `chunk` to your renderer at format.sampleRate
}
// nil is not always the end of the file: check decoder.endReason
```

`open()`, `nextChunk()` and `seek(toSeconds:)` block, so call them from a thread of your own. To have the
package play it as well, see [the render section](docs/usage.md#play-through-the-render-layer).

## Not yet a player

The package decodes, streams and, optionally, renders; today the app drives `Transport` and keeps the queue,
audio session, Now Playing and effects. A player layer above `Transport` is planned ([ADR-0019](docs/decisions/0019-player.md)).

## Documentation

- [Usage](docs/usage.md): decode a file, stream a URL, seek, cancel, show buffering state, play through the render layer.
- [Migrating to PlaybackRender](docs/migrating.md): moving an `AVAudioEngine` player over, step by step.
- [Architecture](docs/architecture.md): how the decoder and the download source work.
- [Decisions](docs/decisions/README.md): why it is built this way.
- [Contributing](CONTRIBUTING.md) and [docs/contributing.md](docs/contributing.md): tests, rebuilding FFmpeg, releasing.

## Licence

The package is [MIT](LICENSE). FFmpeg is LGPL-2.1, shipped as a dynamic framework; what an app must do is in
[ADR-0001](docs/decisions/0001-ffmpeg-for-demux-and-decode.md).
