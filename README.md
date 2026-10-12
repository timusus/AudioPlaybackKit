# AudioPlaybackKit

![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![Platforms](https://img.shields.io/badge/platforms-iOS%2017%20%7C%20macOS%2014-blue)
![SwiftPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen)
![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey)

Play the audio AVPlayer won't, and own the PCM on the way out. A Swift package over FFmpeg for iOS and macOS:
a decoder, a streaming byte source, an output layer, and a `Player` with the audio session and lock screen
on top. Built for Shuttle Podcasts and Shuttle2.

It is built to be checked. 125 conformance fixtures are pinned to hashes of their decoded audio and run
through a fault-injecting reader and a seek matrix modelled on androidx/media, among about 780 tests. The FFmpeg
framework is about 1.6 MB per iOS slice, and the fakes let an app test its own player code.

What an app gets:

- **Formats AVPlayer lacks.** Ogg Vorbis, Ogg Opus, FLAC in Ogg and Matroska/WebM audio, alongside MP3, AAC, M4A/ALAC, FLAC and WAV/AIFF.
- **Playback before the download ends.** `GrowingFileByteSource` reads an HTTP(S) URL while it downloads, with range-request resume, stall detection and retry. An MP4 with its index at the end plays from range requests.
- **Seeks that land on the sample** (VBR MP3 excepted), gapless joins between items (even at different sample rates), and decode that can be cancelled while blocked on the network.
- **A decoder checked against goldens.** Over a hundred fixtures run through a faulting reader and a seek matrix against committed PCM hashes, modelled on androidx/media's tests ([ADR-0008](docs/decisions/0008-conformance-testing-modelled-on-media3.md)).
- **An output layer to replace your `AVAudioEngine` graph** (`PlaybackRender`). One `Transport` drives an `AVSampleBufferAudioRenderer` and its synchronizer: play, pause, seek, speed, a gapless next item, and your effects as `AudioProcessor`s. Position comes back as the frame being heard. A failed renderer or a media-services reset is recovered once, landing paused where it was ([ADR-0018](docs/decisions/0018-render-layer.md)).
- **A player on top** (`PlaybackPlayer`). `Player<Item>` takes your list and keeps the next item armed for a gapless join, with repeat, pause at the end of an item, seconds-based seeks across items, and observable `state`, `position` and `duration`. It owns the `AVAudioSession`: lazy activation, interruptions that resume only when they should, headphones and Bluetooth loss, media-services resets. A failed item stops with an event rather than skipping ([ADR-0019](docs/decisions/0019-player.md)).
- **The lock screen.** `NowPlayingSession` (`PlaybackNowPlaying`) shows a `Player` in Now Playing and routes the remote commands back to it.
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
| `PlaybackPlayerTestSupport` | `FakeAudioSession`, `PlayerTestRig` and `FakeItemFactory`: a `Player` on a fake output and manual clock over items scripted to fail, end early or stall, for testing an app's coordinator. |
| `PlaybackNowPlayingTestSupport` | `FakeNowPlayingInfoCenter` and `FakeRemoteCommandCenter`: a `NowPlayingSession` publishing to fakes, for pressing remote commands and reading what is shown. |
| `FFmpeg` | The LGPL-only FFmpeg as a dynamic framework, for an app with its own C code against libavformat. |

**Which product do I need?** PCM only: `PlaybackDecode` (plus `PlaybackStreaming` for URLs). Your own queue and
audio session over a renderer: add `PlaybackRender`. Playback with the queue, session and interruptions done:
`PlaybackPlayer`, plus `PlaybackNowPlaying` for the lock screen. Each `*TestSupport` product goes in your test
target only. `FFmpeg` is for an app with its own C code against libavformat.

## What it doesn't do

Pick something else if you need:

- HLS, DRM/FairPlay, ICY metadata, crossfade, casting or video. `AVPlayer` covers HLS and FairPlay.
- watchOS, tvOS or Intel Macs. It builds for iOS 17+ and macOS 14+ on Apple silicon.
- Every format. APE, WavPack, DSD and WMA are not built in; SFBAudioEngine or VLCKit cover more.
- Live AAC or Ogg streams that reconnect after a dropped connection; they fail instead ([ADR-0017](docs/decisions/0017-live-streams.md)).
- A download manager. The streaming cache lasts one session.

Known limits: a VBR MP3 without a Xing table seeks by estimate. The API is 0.x and still changing, and
there is one maintainer and no CI. `Player` and `NowPlayingSession` have not yet shipped in an app.

## Install

```swift
.package(url: "https://github.com/timusus/AudioPlaybackKit.git", from: "0.11.0")
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

## Play a list

```swift
import PlaybackDecode
import PlaybackPlayer
import PlaybackRender

let player = Player<URL>(makeSource: { FFmpegItemSource(reader: try FileByteReader(url: $0)) })
player.setItems(urls)
player.play()          // then read player.state, player.position and player.duration
```

Effects (skip-silence, Voice Boost) are `AudioProcessor`s you give the player; shuffle, ads and UI stay in the app. [Usage](docs/usage.md#play-a-list-with-player) covers the rest.

## Documentation

- [Usage](docs/usage.md): decode a file, stream a URL, seek, cancel, show buffering state, play through the render layer, run a `Player`, show it on the lock screen, test it.
- [Migrating to Player](docs/migrating.md): moving Shuttle Podcasts and Shuttle2 off their `AVAudioEngine` players.
- [Device checklist](docs/device-checklist.md): what no test covers, to run on an iPhone before relying on a release.
- [Architecture](docs/architecture.md): how each layer works, from decoder to lock screen.
- [Decisions](docs/decisions/README.md): why it is built this way.
- [Contributing](CONTRIBUTING.md) and [docs/contributing.md](docs/contributing.md): tests, rebuilding FFmpeg, releasing.

## Licence

The package is [MIT](LICENSE). FFmpeg is LGPL-2.1, shipped as a dynamic framework; what an app must do is in
[ADR-0001](docs/decisions/0001-ffmpeg-for-demux-and-decode.md).
