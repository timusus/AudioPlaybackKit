# PlaybackStreaming API cleanup: migration notes

Working file for the release notes; delete once the tag ships. Paths are relative to
`podcasts/main/mobile/ios/` (P) and `shuttle2/ios/` (S). Behaviour is unchanged; this is surface and units.

## Changed

### `GrowingFileListener.playerWillSeek`: seconds, not milliseconds

| Old | New |
|---|---|
| `func playerWillSeek(toMs ms: Int64, generation: Int)` | `func playerWillSeek(to time: TimeInterval, generation: Int)` |

Every other duration in the module is already `TimeInterval` seconds (`Startup`, `readWaitingSince`,
`GrowingFileReadAhead.seconds`, the timeout constants), so this was the one outlier. `Duration` is not
used anywhere in the module. Call sites: divide by 1000 where the app holds ms.

- P `ShuttlePodcasts/Platform/Audio/Spine/GrowingFileSpineCapture.swift:125` (implements)
- P `ShuttlePodcasts/Platform/Audio/Spine/GrowingFileSpineSource.swift:114` (implements; doc at :49)
- P `ShuttlePodcasts/Platform/Audio/Playback/GrowingFileItemSource.swift:89` (calls)
- P `Playback/Sources/Playback/StreamingPCMReader.swift:357` (calls with `Int64(target * 1000)`; becomes `target`; doc at :334)
- P tests: `Playback/Tests/PlaybackTests/StreamingPCMReaderTests.swift:80`,
  `ShuttlePodcastsTests/GrowingFileItemSourceTests.swift:139`, `ShuttlePodcastsTests/PlayerSkipTests.swift:215`,
  `ShuttlePodcastsTests/GrowingFileSpineSourceTests.swift:246,248,256,264,271,494,514,563`
- S: none.

### `GrowingFileStore.init`: the test seams moved to SPI

| Old | New |
|---|---|
| `init(directory:budgetBytes:write:availableCapacity:)` (public) | `init(directory:budgetBytes:)` (public); the four-argument form is `@_spi(Testing) public` |
| `GrowingFileStore.WriteFunction` (public) | `@_spi(Testing) public` |

Use `@_spi(Testing) import PlaybackStreaming` to keep injecting `write` or `availableCapacity`. The
`write` parameter no longer has a default on the SPI init. No app passes either parameter.

- P: none. S: none (`Playback/Sources/S2Playback/Streaming/StreamStore.swift:13` uses `directory:budgetBytes:`).

### `GrowingFileByteSource` is no longer a `URLSessionDataDelegate`

The five `urlSession(...)` methods are internal and the class no longer conforms; an internal
`SessionDelegate` is set on each task. Nothing in either app calls them on a byte source
(`S2Tests/ServerConnectionSessionTests.swift:127` calls S2's own delegate).

## Narrowed to internal

| Symbol | App uses |
|---|---|
| `GrowingFileStore.budget` (instance property) | none; `budgetBytes` stays public as the init default |

Kept public although only tests use them: `GrowingFileByteSource.idleTimeoutSeconds`
(P `Playback/Tests/PlaybackTests/AVAudioEngineBufferingTests.swift:51`), `throughputWindowSeconds` and
`recheckSeconds` (P `Playback/Tests/PlaybackTests/AVAudioEngineSeekRaceTests.swift:96`). `sharedSession`
(P `Playback/Sources/Playback/StreamingPCMReader.swift:131`, S `StreamWarmUp.swift:32`) and `willSeek`
(P `GrowingFileItemSource.swift:12`) are used. `framesPerChunk` and `bytesConsumed` belong to
`PlaybackDecode`, not this module, and are untouched.

Public, unused by either app, kept: `streamProbed(duration:)` and `GrowingFileReadAhead(seconds:fallbackBytes:)`
(the time-based read-ahead; both apps pass bytes), `untrustedCertificateReason`, `leafSHA256(of:)` (an app
pinning a certificate needs it to compute the hash), `GrowingFileStore.directory` (used in P tests),
`fetchedEnd` (a `StreamByteReader` requirement). The `PlaybackStreamingTestSupport` surface is unchanged.
