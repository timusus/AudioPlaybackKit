# Migrating to 0.12.0: public API cleanup

No behaviour or PCM changed; no golden moved.

## Changed symbols

| Old | New | Why |
|---|---|---|
| `ItemSource.duration: Int64?` (also `FFmpegItemSource`, `FakeItemSource`) | `frameCount: Int64?`, now required of every conformer (no default) | It is a count of frames, not a time; the units rule in `usage.md` says a time is seconds. A conformer still implementing `duration` fails to compile instead of silently reporting an unknown length. |
| `Player.hasNext`, `Player.hasPrevious` (public) | internal | No app or test used them; `availableCommands` reports the same facts. |
| `PlaybackSuppression.none` | `.unsuppressed` | `.none` collides with `Optional.none`. |

## App call sites

Shuttle Podcasts (`mobile/ios/`):

- `ShuttlePodcasts/Platform/Audio/Playback/GrowingFileItemSource.swift:54`: `var duration: Int64? { lock.withLock { opened?.source.duration } }`
  becomes `var frameCount: Int64? { lock.withLock { opened?.source.frameCount } }`.
- `ShuttlePodcastsTests/GrowingFileItemSourceTests.swift:160` (`RecordingSource`): `var duration: Int64? { inner.duration }`
  becomes `var frameCount: Int64? { inner.frameCount }`.
- `ShuttlePodcastsTests/GrowingFileItemSourceTests.swift:178` (`FailingSource`): `var duration: Int64? { nil }` becomes `var frameCount: Int64? { nil }`.
- `ShuttlePodcastsTests/PlayerProcessorChainTests.swift:257` (`GappedSource`): `var duration: Int64? { total }` becomes `var frameCount: Int64? { total }`.

Shuttle2: no `ItemSource` conformer on `main` and no use of `PlaybackSuppression` or `hasNext`/`hasPrevious`.
Neither app uses `PlaybackSuppression.none`.

## Kept on purpose

- `StreamAudioFormat` (PlaybackDecode) and `PCMFormat` (PlaybackRender) stay apart: one is what the
  container says about the source (rate, duration, codec), the other the decoded output. Both now cross-reference.
- `seekToNext()` / `seekToPrevious()` beside `skipToNext()` mirror media3, and Shuttle Podcasts overrides them.
- `FFmpegStreamDecoder.read(into:maxFrames:)` (Shuttle2) and `nextChunk()` (Podcasts) are both in use.

## Left for later

- `pauseAtEndOfItem` to `pausesAtEndOfItem` (about 25 uses, mostly tests).
