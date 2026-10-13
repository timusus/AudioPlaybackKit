# Migrating to 0.12.0: public API cleanup

No behaviour or PCM changed; no golden moved.

## Changed symbols

| Old | New | Why |
|---|---|---|
| `ItemSource.duration: Int64?` (also `FFmpegItemSource`, `FakeItemSource`) | `frameCount: Int64?` | It is a count of frames, not a time; the units rule in `usage.md` says a time is seconds. |
| `Player.hasNext`, `Player.hasPrevious` (public) | internal | No app or test used them; `availableCommands` reports the same facts. |

## App call sites

Shuttle Podcasts:

- `mobile/ios/.../GrowingFileItemSource.swift:54`: `var duration: Int64? { lock.withLock { opened?.source.duration } }` becomes
  `var frameCount: Int64? { lock.withLock { opened?.source.frameCount } }`.

Shuttle2: none.

## Kept on purpose

- `StreamAudioFormat` (PlaybackDecode) and `PCMFormat` (PlaybackRender) stay apart: one is what the
  container says about the source (rate, duration, codec), the other the decoded output. Both now cross-reference.
- `seekToNext()` / `seekToPrevious()` beside `skipToNext()` mirror media3, and Shuttle Podcasts overrides them.
- `FFmpegStreamDecoder.read(into:maxFrames:)` (Shuttle2) and `nextChunk()` (Podcasts) are both in use.

## Left for later

- `pauseAtEndOfItem` to `pausesAtEndOfItem` (about 25 uses, mostly tests).
- `PlaybackSuppression.none` collides with `Optional.none`.
