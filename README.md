# AudioPlaybackKit

[![CI](https://github.com/timusus/AudioPlaybackKit/actions/workflows/ci.yml/badge.svg)](https://github.com/timusus/AudioPlaybackKit/actions/workflows/ci.yml)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
![Platforms](https://img.shields.io/badge/platforms-iOS%2017%20%7C%20macOS%2014-blue)
![SwiftPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen)
![License: MIT](https://img.shields.io/badge/license-MIT-lightgrey)

An audio playback engine for iOS and macOS apps that need more than AVPlayer gives them: formats it
can't open, and access to the decoded samples before they reach the speaker. FFmpeg decodes; the
package handles streaming, output, the audio session and the lock screen around it. It is the
playback engine for Shuttle Podcasts and Shuttle2.

## Why use it

AVPlayer plays a fixed set of formats and keeps the PCM to itself. Going to `AVAudioEngine` instead
gets you the samples, but leaves you writing the decoder, the session handling and gapless playback
yourself. This package is that layer, built once.

- **Formats AVPlayer can't play.** Ogg Vorbis, Opus, FLAC in Ogg, Matroska/WebM audio, WavPack, WMA
  (v1/v2), DSD (DSF and DFF, decoded to PCM) and Monkey's Audio, alongside MP3, AAC, ALAC, FLAC and
  WAV/AIFF. Each format but Monkey's Audio has a conformance fixture whose decoded output is pinned in
  tests ([ADR-0008](docs/decisions/0008-conformance-testing-modelled-on-media3.md)).
- **Your effects on every format.** Effects such as skip-silence, Voice Boost or EQ are
  `AudioProcessor`s in the output chain, so they apply to whatever was decoded
  ([ADR-0018](docs/decisions/0018-render-layer.md)).
- **Play while downloading.** `GrowingFileByteSource` plays an HTTP(S) URL as it downloads, resuming
  with range requests after a drop or a stall. An MP4 with its index at the end plays too.
- **Accurate seeks and gapless joins.** Seeks land on the sample (a VBR MP3 without a seek table
  excepted), and consecutive items join without a gap, even across sample rates.
- **The session behaviour users notice.** `Player` owns the `AVAudioSession`: it resumes after an
  interruption only when it should, pauses when headphones or Bluetooth drop, and recovers from a
  media-services reset paused where it was. A failed item stops with an event rather than skipping
  silently ([ADR-0019](docs/decisions/0019-player.md)). `NowPlayingSession` puts it on the lock
  screen, Control Centre and CarPlay.
- **Your player code is testable.** Fakes for the output, clock, audio session and Now Playing let an
  app drive its own playback logic deterministically, without a device.
- **Shippable in a closed-source app.** FFmpeg is built LGPL-only and embedded as a dynamic framework,
  which is what the licence requires ([ADR-0001](docs/decisions/0001-ffmpeg-for-demux-and-decode.md)).

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
- Every format. WMA Pro/Lossless, DSD passthrough (DoP) and other exotic codecs are not built in; SFBAudioEngine or VLCKit cover more.
- Live AAC or Ogg streams that reconnect after a dropped connection; they fail instead ([ADR-0017](docs/decisions/0017-live-streams.md)).
- A download manager. The streaming cache lasts one session.

Known limits: a VBR MP3 without a Xing table seeks by estimate. The API is 0.x and still changing, and
there is one maintainer. The package is young and so far proven in one shipping app; `Player` and
`NowPlayingSession` have not yet shipped in an app.

## Install

```swift
.package(url: "https://github.com/timusus/AudioPlaybackKit.git", from: "0.13.0")
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

- [Usage](docs/usage.md): decode a file, stream a URL, seek, cancel, handle errors, show buffering state, play through the render layer, run a `Player`, show it on the lock screen, test it.
- [Recipes](docs/recipes/README.md): play a file, stream a URL, a gapless queue, the lock screen, errors, seeking, testing your code, writing an `AudioProcessor`; each one is a test that runs offline.
- [Migrating to Player](docs/migrating.md): moving Shuttle Podcasts and Shuttle2 off their `AVAudioEngine` players, and from 0.11 to 0.12 (changed symbols and each app call site).
- [Device checklist](docs/device-checklist.md): what no test covers, to run on an iPhone before relying on a release.
- [Architecture](docs/architecture.md): how each layer works, from decoder to lock screen.
- [Decisions](docs/decisions/README.md): why it is built this way.
- [Contributing](CONTRIBUTING.md) and [docs/contributing.md](docs/contributing.md): tests, rebuilding FFmpeg, releasing.

## Licence

The package is [MIT](LICENSE). FFmpeg is LGPL-2.1, shipped as a dynamic framework; what an app must do is in
[ADR-0001](docs/decisions/0001-ffmpeg-for-demux-and-decode.md).
