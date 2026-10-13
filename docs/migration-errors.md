# Migrating to structured errors

Failures now carry a `PlaybackErrorCategory` from the byte source through the decoder to `PlaybackError`
([ADR-0029](decisions/0029-structured-errors.md), [usage](usage.md#handle-errors)). This page lists every
changed symbol and each call site in the two apps.

## Changed symbols

| Old | New |
|---|---|
| `StreamDecoderError.failed(status: Int32)` | `StreamDecoderError.failed(StreamFailure)`; the libav code is `failure.averror` (the real AVERROR, no longer `-1`) |
| `StreamByteReaderError.transport(String)` | `StreamByteReaderError.failed(StreamFailure)`; the old string is `failure.detail` |
| `GrowingFileByteSource` read failures, all `.transport` | `.failed` with `.network`, `.http(status:)`, `.unsupported` (not audio), `.malformed` (out of range) or `.io` (disk) |
| `FileByteReader` open and read failures (`CocoaError`, `POSIXError`) | `.failed` with `.io` |
| C `stream_decoder_open_with(..., int *status)` | gains a trailing `int *averror`, set when libav failed |

## New symbols

- `PlaybackErrorCategory` (`PlaybackDecode`): `io`, `network`, `http(status:)`, `malformed`, `unsupported`,
  `cancelled`, `internal`.
- `StreamFailure` (`PlaybackDecode`): `category`, `detail`, `averror`, `urlError`.
- `StreamDecoderError.category` and `StreamByteReaderError.category`. The other cases map as:
  `cancelled` to `.cancelled`; `unavailable` and `unseekable` to `.unsupported`; `interrupted` and
  `invalidState` to `.internal`.
- `FFmpegStreamDecoder.error`: the failure behind a nil `nextChunk()` with `endReason == .failure`.
- `PlaybackError.category` (`PlaybackPlayer`): the underlying error's category, or `.internal` for an
  error the library did not raise. `PlaybackPlayer` now depends on `PlaybackDecode`.
- C `stream_decoder_last_averror(handle)`: the AVERROR behind the last failed call.

The unchanged cases (`cancelled`, `interrupted`, `unseekable`, `invalidState`, `unavailable`) keep their
meaning, and an app's reader that throws them needs no change. Any other error an app's reader throws now
reaches the caller as `.failed` with `.io`, or `.network` for a `URLError`, instead of `.failed(status: -1)`.

## Shuttle Podcasts

Nothing matches `.failed(status:)` or `.transport`, so the bump compiles unchanged. Places that can adopt
the category:
Paths are under `mobile/ios/`.

| Call site | Today | Change |
|---|---|---|
| `ShuttlePodcasts/Platform/Audio/Playback/GrowingFileItemSource.swift:72-75, 113, 131` | Matches `.interrupted`, `.cancelled`, `invalidState` | None |
| `ShuttlePodcasts/Platform/Audio/Playback/PlayerStateBridge.swift:138, 165-169` | Reads `error.underlying` and `kind` | Branch on `error.category` for retry versus skip |
| `Playback/Sources/Playback/StreamingPCMReader.swift:97, 318, 444, 462` | Reads `endReason`, matches `.cancelled` | Optional: log `decoder.error` on `.failure` |
| `Playback/Sources/Playback/AVAudioEnginePlaybackController+Producing.swift:107-108, 405, 426` | Reads `endReason`, matches `.cancelled` | Optional: surface `decoder.error`'s category |
| `Playback/Tests/PlaybackTests/StreamingPCMReaderTests.swift:111` | Matches `.cancelled` | None |

## Shuttle2

Nothing matches the changed cases; the bump compiles unchanged.

| Call site | Today | Change |
|---|---|---|
| `ios/Playback/Sources/S2Playback/Streaming/StreamedTrackReader.swift:8, 37, 49, 54` | Throws `.interrupted`; other errors pass through | None. Its other errors now arrive as `.failed` with `.io`, or `.network` for a `URLError`; throw `.failed(StreamFailure(.http(status:), ...))` to keep a status |
| `ios/Playback/Sources/S2Playback/Engine/TrackPCMSource.swift:155-184` | Catches `cancelled`, `interrupted`, `unseekable` | None; a catch-all can branch on `category` |
| `FFmpegMusicDecodeTests.swift:168, 186` | Matches unchanged cases | None |
| `StreamedPlaybackTests.swift:249` | Matches unchanged cases | None |
