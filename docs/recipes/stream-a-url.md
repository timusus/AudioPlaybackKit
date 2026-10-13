# Stream a URL

Code: [`StreamAURLRecipe.swift`](../../Tests/RecipesTests/StreamAURLRecipe.swift). Link `PlaybackStreaming`
as well as `PlaybackDecode`.

`GrowingFileByteSource` downloads the URL into a growing file and the decoder reads it as it grows.
When the connection drops, the source resumes with a `Range` request from where the bytes stopped
([ADR-0004](../decisions/0004-one-recovery-layer-in-the-byte-source.md)); the decoder only sees a read
that takes longer. The test serves a 20 s WAV from `LoopbackMediaServer`, which closes every connection
after 100 000 bytes.

```swift
let source = GrowingFileByteSource(
    url: server.url,
    authHeaders: [:],               // already resolved; add "Authorization" here for a private feed
    store: .temporary()             // an app uses `.shared`, or a store of its own
)
// The source and its partial file live until cancelled.
defer { source.cancel() }

let decoder = FFmpegStreamDecoder(reader: source)
// Lets FFmpeg's MP3 footer probe read end-of-file instead of cancelling the head download.
source.isProbing = true
let format = try decoder.open()
source.isProbing = false

while let chunk = decoder.nextChunk() { /* ... */ }

XCTAssertEqual(decoder.endReason, .eof)
XCTAssertGreaterThan(server.requestedRanges.count, 1, "the drop was not resumed with a new request")
```

Handed to a `Player` inside an `FFmpegItemSource`, the transport cancels the source for you.

Do not recreate the source or re-seek on a network change; it watches the path itself. To go offline-first,
ask `store.completedFile(for: url)` and play a finished download with `FileByteReader`. The rest
(redirects, auth origin, cellular read-ahead, self-signed servers) is in
[Usage](../usage.md#play-a-url-while-it-downloads).
