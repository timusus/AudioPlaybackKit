# Usage

From adding the package to decoding a file, playing a URL while it downloads, and running a `Player` with
its lock-screen controls (an app that wants playback rather than PCM starts at
[Play a list with `Player`](#play-a-list-with-player)). Signatures and
parameters are in the doc comments of the types named here; this page covers the order of calls and the
behaviour you must know. Threading and blocking apply throughout: `open()`, `nextChunk()`,
`read(into:maxFrames:)` and `seek(toSeconds:)` block, so run them on a thread of your own, one thread per decoder.

## Add the package

```swift
dependencies: [
    .package(url: "https://github.com/timusus/AudioPlaybackKit.git", from: "0.11.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "PlaybackDecode", package: "AudioPlaybackKit"),
        .product(name: "PlaybackStreaming", package: "AudioPlaybackKit"),   // only to play URLs
    ]),
]
```

Pin a tag, never a branch. FFmpeg is a dynamic `FFmpeg.framework` that links its own system libraries;
Xcode embeds it in the app with no build-phase change. The `FFmpeg` product is only for an app with its
own C code against libavformat (`#include <libavformat/avformat.h>` or `import CFFmpeg`), and the app
must link exactly one FFmpeg. An app that reaches PlaybackDecode only through its own framework or
extension target must still embed and sign `FFmpeg.framework` in the app itself.

## Supported formats

MP3, AAC (ADTS and LATM), MP4/M4A (AAC, ALAC), Ogg (Vorbis, Opus, FLAC), Matroska/WebM (Opus, Vorbis), FLAC, PCM WAV/AIFF, WavPack, WMA v1/v2 (ASF), DSD (DSF/DFF, decoded to PCM; no DoP passthrough), Monkey's Audio (APE).

WavPack seeking is broken (#175): seeks into the stream fail. WMA has known fault-resume and unknown-length seek findings; both are pinned in `KnownIssues+Codecs.swift` (#171). Monkey's Audio (APE) is untested: it has no conformance fixture, as no encoder is available.

Sample-accurate seek can land early on fragmented MP4 of unknown length (known-issue fixtures #61 and #62).

## Decode a file

```swift
import PlaybackDecode

let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: fileURL))
let format = try decoder.open()          // sampleRate, channelCount, duration (nil if unknown), codec, container

while let chunk = decoder.nextChunk() {  // [Float], interleaved, up to 4096 frames
    // schedule `chunk` at format.sampleRate, format.channelCount channels
}
if decoder.endReason != .eof { /* .failure, .cancelled or .interrupted */ }
```

`nextChunk()` returning nil is not always the end of the file: check `endReason`, or a network failure
looks like a short track. Output is Float32 at the source's own rate, not resampled.

**Duration is an estimate for a headerless CBR MP3.** With no Xing/Info/VBRI header, `format.duration` is
a bitrate estimate over the source length, so trailing non-audio bytes inflate it (one fixture reports
12.2 s for 2.82 s of audio); with no source length it is nil. Open reads nothing extra to check (a tail
scan would restart a `GrowingFileByteSource` download). Once `endReason == .eof`,
`Double(mediaFramesRead) / format.sampleRate` is the real length, as media3's `ConstantBitrateSeeker`
re-emits its SeekMap when the decode reaches the garbage. A seek past the real end finishes at `.eof`.

`open()` throws `StreamDecoderError`; a format the build lacks arrives as `.failed` with category
`.unsupported` (see [Handle errors](#handle-errors)). The probe
is budgeted at 64 KiB / 1 s (libavformat's own is 5 MB / 5 s); a heavier file passes
`probeBudget: StreamProbeBudget(bytes:analyzeDuration:)` to the initialiser. Header-described formats
(FLAC, ALAC, WAV) skip the probe (`skippedProbe`); `forcesProbe: true` restores it.

**Fixed output format.** A player running one graph across tracks (gapless, mixed sample rates) calls
`setOutputFormat(sampleRate:channelCount:)` after `open()` and before the first read or seek. The
decoder then resamples and remixes every frame (mono is spread to every channel at full level).
`read(into:maxFrames:)` fills your buffer without allocating. A seek still returns media seconds
([ADR-0010](decisions/0010-the-decoder-owns-output-format-conversion.md)).

## Play a URL while it downloads

```swift
import PlaybackDecode
import PlaybackStreaming

let source = GrowingFileByteSource(
    url: url,
    authHeaders: ["Authorization": "Bearer \(token)"],   // already resolved; [:] for none
    onEvent: { event in /* .transaction, .download, .seekLanded, .readWaiting, .readResumed */ }
)
defer { source.cancel() }

let decoder = FFmpegStreamDecoder(reader: source)
source.isProbing = true
let format = try decoder.open()
source.isProbing = false

while let chunk = decoder.nextChunk() { /* schedule it */ }
```

- **Always call `cancel()`.** A running URLSession task retains its delegate, which is the source.
  Without it the source and its partial file leak. Handed to `Player` or `Transport` in an
  `FFmpegItemSource`, the transport does it: `ItemSource.release()` cancels the reader once the item
  is replaced, removed, passed or stopped.
- **Set `isProbing` around `open()`.** FFmpeg's MP3 open reads the last 128 bytes (an ID3v1 footer).
  While probing, that read answers end of file at once instead of cancelling the head download
  ([ADR-0003](decisions/0003-growing-file-playback.md)).
- **The decoder blocks while it waits for bytes.** That is how buffering shows up. The source retries
  drops itself; a read throws `StreamByteReaderError.failed` only when retries and the 30 s link
  window are spent, after the bytes already downloaded have been read. Play out what you have decoded,
  then show an error at that position.
- **Do not re-seek or recreate the source on a network change.** The source watches the network path and
  resumes from its frontier. A host that does the same races it
  ([ADR-0004](decisions/0004-one-recovery-layer-in-the-byte-source.md)).
- **Auth headers stay on the origin.** A redirect to another origin (a CDN) and its later restarts carry
  none of them. The origin is scheme, host and port; a redirect to the same host that upgrades from `http`
  to `https` (port 80 to 443) keeps them, a downgrade to `http` does not. `Range` and `Accept-Encoding` are
  the package's own: a header of either name is ignored.
- **Extra headers.** `GrowingFileConnectionPolicy.headers` adds request headers for the origin, with the same redirect rule as `authHeaders`.
- **Mutual TLS.** Pass `clientCredential: { space in ... }` to answer the origin's client-certificate challenge with an identity `URLCredential`; nil keeps the system's handling, and no other origin is asked.
- **Self-signed servers.** Pass `connectionPolicy: GrowingFileConnectionPolicy(trustedLeafSHA256: [...])`
  with the fingerprint the user trusted. It is an exception, not a pin: the system evaluates first,
  and only a certificate it refuses is accepted by fingerprint. Otherwise the read fails with
  a `.network` failure whose detail is `untrusted_certificate`, unretried in every case. Other certificate, TLS, ATS and
  bad-URL errors fail unretried too.
- **Cache.** A download whose transactions together cover `[0, total)` is kept in a `GrowingFileStore` (default
  `.shared`, 1 GiB, least recently played out). Before streaming, ask
  `store.completedFile(for: url)` and play that with `FileByteReader`. If the URL carries a
  per-session token, pass `cacheKey:` (the URL without it) to the source and to `completedFile(for:)`. Call `sweepPartials()` at launch,
  and give each owner (podcasts, music) its own store so one cannot evict the other's files.
- **Cellular data.** By default a source downloads the whole file on any network. Pass
  `readAhead: GrowingFileReadAhead(bytes:)` to cap it while the path is expensive or in Low Data
  Mode: the source stops that many bytes ahead of the decoder and resumes from where it stopped at
  half of it. To give it in time, pass `GrowingFileReadAhead(seconds: 60, fallbackBytes: ...)` and
  call `source.streamProbed(duration:)` with `StreamAudioFormat.duration` after the decoder opens: the
  source converts with the stream's bitrate (total length over duration), and uses `fallbackBytes`
  until both are known, in whichever order they arrive. Wi-Fi, and a host that ignores ranges,
  still download whole, and a file played to the end is cached as before ([ADR-0013](decisions/0013-read-ahead-on-expensive-paths.md)).
- **Seeking to exactly the end** reads zero bytes even before the length is known, as media3's
  `DefaultHttpDataSource` does with the host's `416 bytes */N`. Seeking past the end, once the
  host shows it, fails the read at once with a `.malformed` failure (`out_of_range ...`), with no retry.

## Units

**A time is a `TimeInterval` in seconds.** Where an API also deals in frames or bytes, the label says
`Seconds` (`seek(toSeconds:)`, `Transport.setCurrent(startSeconds:)`); the `Player` layer, which has only
seconds, does not (`seek(to:)`, `position`, `duration`). Counts of PCM frames are `Int64` and named for
frames (`frameCount`, `mediaStartFrame`, `mediaFramesRead`, `maxFrames`). The byte-source APIs
(`StreamByteReader`, `FileByteReader`, `GrowingFileByteSource`, `GrowingFileSnapshot`: `position`,
`seek(to:)`, `fetchedEnd`, `base`, `frontier`) are byte offsets, and a parameter taking either bytes or
seconds is labelled with its unit (`GrowingFileReadAhead`).

## Seek

```swift
let landed = try decoder.seek(toSeconds: 600)
```

Use `landed`, not 600, as your position. The landing is sample-accurate
([ADR-0009](decisions/0009-seeks-are-sample-accurate.md)) with one exception: a VBR MP3 far from a
frame of known time (no MP3 frame carries its time) lands on an estimate from its Xing table or
bitrate, and the estimate is what comes back. If the stream ended at the target, `seek` returns
normally and `endReason` is `.eof`. At a fixed output rate the first frame after a seek is within one
output frame, not bit-identical to the uninterrupted decode.

A forward-only source (a reader whose `seek(to:)` throws `StreamByteReaderError.unseekable`, such as
an unknown-length chunked transcode) opens and decodes MP3, FLAC, Ogg and MP4 sequentially. A seek that needs a position it
refuses throws `StreamDecoderError.unseekable`, distinct from `.failed(_:)` (a corrupt stream or a source error),
whether or not the reader knows its `totalLength`.
The decoder has failed after it: `endReason` is `.failure` and reads return nothing, so open a new
decoder over a seekable source. A seek that libavformat can serve from bytes it still holds succeeds.
A seek or read that fails on a source error (`.failed(_:)` with category `.network`, say) is not
terminal: a later seek reads again, so a player resumes the same decoder once the source is back.

Chained Ogg (streams concatenated byte for byte) decodes sequentially across its links, including a
change of channel count or sample rate, which is converted to the open format. Seeking into a later
link is unsupported ([#48](https://github.com/timusus/AudioPlaybackKit/issues/48)), as in FFmpeg and
media3: the seek lands in the first link.

With a growing-file source, a seek to bytes already on disk is served from the file; a seek into a
hole restarts the download at the target, into the same file (a short hop ahead waits instead). Call `source.willSeek(generation:)` first only if you want the
transaction paired with your seek in `snapshot` and events. A seek past a known `totalLength` throws
`.unseekable` (the total itself is the end of the stream), so a server's over-estimated length is refused, not waited on.

## Cancel and interrupt

```swift
decoder.cancel()      // any thread: the stream ends for good, endReason == .cancelled
decoder.interrupt()   // any thread: only the blocked call ends, endReason == .interrupted
```

Use `interrupt()` when the pull loop is stuck on a slow read and the user has seeked: stop treating
the nil as an end and call `seek(toSeconds:)`, which clears it. If that seek is to exactly the frame
the interrupted read would have returned, the decode resumes without a flush (MP3 and MP4 bit-exactly).
Use `cancel()` when you throw the decoder away.

## Handle errors

Every failure carries a `PlaybackErrorCategory`, modelled on media3's `PlaybackException` error-code
groups ([ADR-0029](decisions/0029-structured-errors.md)). Act on the category; the rest is for logs.

| Category | Means | Typical response |
|---|---|---|
| `.network` | No connection, a timeout, a dropped or refused TLS connection, a short body; also the errors no retry fixes (untrusted certificate, bad URL, ATS), told apart by `urlError` | Retry when the network is back, unless `urlError` is permanent |
| `.http(status:)` | The server answered with a status no retry fixed | 401/403: refresh auth; 404/410: skip; 408/429/5xx: retry later with backoff |
| `.io` | A local file could not be opened, read or written | Re-download or delete the file |
| `.malformed` | The bytes are damaged or inconsistent (a range past the server's end) | Skip; re-download if cached |
| `.unsupported` | No demuxer or decoder, no audio stream, a page where audio should be, no FFmpeg | Skip, and do not retry |
| `.cancelled` | The source was cancelled under the decoder | Usually your own cancel: ignore |
| `.internal` | Allocation, misuse, an error the library did not raise | Report |

```swift
switch error.category {                       // StreamDecoderError, StreamByteReaderError or PlaybackError
case .network, .http(status: 500...), .http(status: 408), .http(status: 429): retryLater()   // with backoff
case .http(status: 401), .http(status: 403): refreshAuthAndRetry()
case .unsupported, .malformed, .http: skip()
case .io: redownload()
case .cancelled: break
case .internal: report(error)
}
```

- **`StreamDecoderError.failed(StreamFailure)`** carries the category, a `detail` for logs, the libav
  `averror` when libavformat reported one, and the `urlError` behind a network failure. After a nil
  `nextChunk()` with `endReason == .failure`, `decoder.error` is the failure.
- **A reader's own failure keeps its category** through the decoder, whatever FFmpeg made of it: a
  connection lost during the probe is `.network`, not "not a container". An app's reader throws
  `StreamByteReaderError.failed(StreamFailure(...))` to choose the category; a `URLError` counts as
  `.network` and any other error as `.io`.
- **`PlaybackError.category`** on `itemFailed` and `Player.error` reads the same category off the
  underlying error; a failure the library did not raise (your factory's, the output's, the session's)
  is `.internal`.
- **FFmpeg skips damage rather than failing.** A corrupt frame is dropped, and a truncated file or a
  run of garbage ends at `.eof`, as media3's extractors do. `.malformed` therefore comes from the
  source (a range past the end) far more often than from the decoder.

## Show buffering and download state

`source.snapshot` is readable from any thread: `base`, `frontier`, `totalLength`, `isComplete`,
`downloadBytesPerSecond`, `fileURL`; `base` and `frontier` are the range on disk the reader is in,
and `isComplete` says it reaches the end. `readWaitingSince` is the source clock's time the decoder's read
parked for bytes (nil when none waits), and `now - readWaitingSince` is the stall. `onEvent` delivers changes without polling: `.readWaiting(since:)` when the decoder's read parks for bytes and `.readResumed` when it ends (once per stall, on the decoder's thread outside the source's lock), `.transaction` when a
response is accepted, `.download` at most once a second, `.seekLanded` when a seek was served from the
file already on disk. A host that wants protocol-shaped callbacks implements `GrowingFileListener` and
calls it from `onEvent`; the source does not take a listener. `playerWillSeek(to:generation:)` takes the
target in seconds, like every time in this module. A listener reads the file back through
`fileURL`, so it never sees a byte the decoder did not have.

## Play through the render layer

`PlaybackRender` (depends on `PlaybackDecode`) replaces an `AVAudioEngine` graph with one `Transport`
([ADR-0018](decisions/0018-render-layer.md)). It owns the `AVSampleBufferAudioRenderer` and its
synchronizer, writes PCM ahead of the playhead as far as the renderer takes it, joins items gaplessly, and
reports what is heard. The app keeps the `AVAudioSession` (category, activation, interruptions), Now
Playing and remote commands, the queue, and the effects. The transport never touches the session: set
the category and activate it before `play()`.

```swift
import PlaybackRender

let transport = Transport<Track.ID> { event in          // called on the transport's queue
    switch event {
    case .position(let id, let seconds, let duration, let isSeekable): break   // media time of `id`; duration nil when unknown
    case .crossed(let id, let format): break            // `id` is now heard, decoded at `format`; advance your queue
    case .formatChanged(let id, let format): break      // `id` is now heard in another decoded format
    case .status(let status): break                     // .paused, .buffering, .playing, .ended
    case .sought(let id, let seconds, let applied): break  // a setCurrent or seek was taken; if applied, events before it are stale
    case .failed(let id, let error): break              // paused, unless `id` is a next item not yet heard; `id` is nil when the output refused audio
    case .recovered: break                              // output rebuilt, paused at the heard position; show paused
    }
}

let source = FFmpegItemSource(reader: try FileByteReader(url: fileURL))   // or a GrowingFileByteSource
transport.setCurrent(item: track.id, source: source, startSeconds: 0)
transport.play()
transport.seek(item: track.id, toSeconds: 90)
transport.setRate(1.5)           // pitch kept; pause() stops, rate 0 is not allowed
transport.setVolume(0.5)         // 0...1, applied at once
```

Every method returns at once and runs in call order on the transport's queue. `Item` is any
`Hashable & Sendable` name for a queue entry. Positions are seconds of the item's media time; a start or
seek lands on the nearest frame, so a stored resume point seeks back to the frame it was reported at. Use
the `position` events for the UI and for `MPNowPlayingInfoCenter`; their `duration` is the item's length
in seconds as FFmpeg probed it, nil for a live stream or a body of unknown length, and `isSeekable` is
the source's `ItemSource.isSeekable`. `.ended` is not final: a
`transport.setNext(item:source:)` made after it plays that item on from the end, without a flush. (`Player`
has no `setNext`; it arms the next item of its list itself.)
`setCurrent` replaces everything set, so it is also how a skip or a track change by the user works.
A source belongs to one `setCurrent` or `setNext`; make a new `FFmpegItemSource` each time.
A source of your own must implement `release()`, which has no default: a wrapper forwards it to the
source it wraps, and a source holding nothing beyond memory leaves it empty.
A source whose format changes mid-item (a server stream re-opened at a time offset that comes back at
another rate or channel count) reports it through `currentFormat`; from then on its frames count at the
new rate. The audio before the change plays out, the processors and output are reconfigured, and the
position carries on in seconds, as media3's `DefaultAudioSink` reconfigures within one period. A
wrapper forwards `currentFormat` too: it has a default, nil, for a format fixed at `open()`.

**Gapless.** Call `setNext(item:source:)` for the track after the current one as soon as the app
knows it, and again when the queue changes (the last next item is replaced if decode has not reached it;
`clearNext()` removes it). Items of different sample rates join in one stream. `.crossed` says when the
speaker reached the new item. An `ItemSource.open()` may block resolving its URL: the next item opens as decode of the
item before ends, up to 30 s ahead of the join, and one removed, replaced or skipped while it opens is interrupted through
`interrupt(through:)`.

**Effects.** Skip-silence, Voice Boost, ReplayGain, EQ and limiters are `AudioProcessor`s passed to
`setProcessors(_:)`. They run on interleaved Float32 PCM on the transport's queue, in order. A stage
that keeps every frame (EQ, gain, a limiter without lookahead) implements `process(_:)` and rewrites
the chunk's own buffer, so the chain copies nothing; one that drops frames (`ProcessorOutput.dropped`,
so positions stay in media time), holds them back or changes the channel count is a
`BufferingAudioProcessor` (ADR-0026). No stage adds frames. `configure(_:)` and `flush(_:)` may
allocate; `process(_:)` and `queueInput(_:)` run per chunk and should not. A
processor cannot change the sample rate; `configure(_:)` receives the item's format, so a filter that
depends on the rate (an EQ) derives its coefficients there and again after each `flush(_:)`. The
chain is drained and flushed at every item change, gapless joins included, at the start, after a
seek and at a format change within an item (a source re-opened at another rate or channel count:
`configure(_:)` then runs again mid-item with the new format, and `flush(_:)` names the same item), and `flush(_:)` gets a `StreamMetadata`: the `item` whose frames follow (the app's own, as given
to `Transport` or `Player`; cast it back) and its `mediaStartFrame`. ReplayGain reads its gain for
`metadata.item` there (ADR-0021). Filter memory and a limiter's envelope reset at each join. Adding or
removing a processor, changing its `isActive` or changing its output format needs another
`setProcessors` call, which never flushes: the old chain drains into the queued audio and the new
one takes over at the next chunk. A processor's own parameters (a gain, EQ bands, or an "enabled"
flag it reads inside a stage that stays `isActive`) apply live, read under its own lock.

**Processors run at write time.** The transport writes up to 30 s ahead of the playhead, so a
processor's own parameter change would reach the speaker only after that audio. `setProcessors` and
`processorsChanged()` (after a parameter change) therefore flush and re-feed from the heard frame, as a
seek does: the change is heard at once, after a brief rebuffer. Fades, ducks and mutes go through
`setVolume`, which acts at once without a flush: the app calls it repeatedly from its own timer or display link.

**Failure.** A failed renderer or a media-services reset is recovered once: the transport rebuilds
the output, lands paused at the same position and sends `.recovered`, and the app calls `play()` again. A second failure
surfaces as `.failed`, and `play()` does nothing until a `seek`, `setCurrent` or `setProcessors`.
A source or processor error that stops an item also arrives as `.failed(item:error:)`. When the item
is a next one decode reached early, it is dropped and the current item plays on without a pause, so
the app chooses what follows; the heard item's failure pauses.

### Moving an app over

Both apps move onto `Player`, not `Transport`, because the player owns the session, the advance and the
recovery an app would otherwise write twice. The per-app tables are in [migrating.md](migrating.md).

## Play a list with `Player`

`PlaybackPlayer` (depends on `PlaybackRender`) is the layer an app's playback controller wraps
([ADR-0019](decisions/0019-player.md)): an ordered list of your items, play intent and state, position
in seconds, seeks across items, gapless advance, repeat, and the `AVAudioSession` rules. It is
`@MainActor` and `@Observable`, and follows media3's `Player`: `playWhenReady` is what the app wants,
`state` is what the transport reports, and neither writes the other. Shuffle, sleep timers, and
what an item is stay in the app.

### Create one

`Item` is your own `Hashable & Sendable` type (an episode, a track). The factory runs on the main actor
when the player is about to decode an item, so construct a source and return; `FFmpegItemSource`
opens lazily. The same item may appear twice in the list.

```swift
import PlaybackDecode
import PlaybackPlayer
import PlaybackRender
import PlaybackStreaming

let player = Player<Episode>(
    makeSource: { episode in
        FFmpegItemSource(reader: GrowingFileByteSource(url: episode.url, authHeaders: [:]))
    },
    audioSession: .spokenAudio      // or .longFormAudio (the default) for music
)
player.setItems(episodes, startIndex: 0, startPosition: saved)   // seconds
player.play()
```

The category is set at init, but the session is activated on the first `play()`, off the main thread.
`.spokenAudio` is `.playback` in mode `.spokenAudio`, so another app's prompt pauses you instead of
ducking you; `.longFormAudio` keeps long-form route sharing for AirPlay 2. On iOS,
`AudioSessionConfiguration(category:mode:routeSharingPolicy:options:)` builds a custom one; macOS has only
the two presets. `timePitchAlgorithm:` picks the `AVAudioTimePitchAlgorithm` for rate changes.

#### AirPlay

Both presets set `.playback` with `routeSharingPolicy: .longFormAudio`, and output is an
`AVSampleBufferAudioRenderer` on an `AVSampleBufferRenderSynchronizer`, so AirPlay 2 buffered and
multi-room playback work with no further code. The app must:

- list `audio` in `UIBackgroundModes` in Info.plist, or playback stops when the app leaves the foreground;
- show an `AVRoutePickerView` (or `MPVolumeView`'s route button) so the user can pick a speaker;
- keep `.mixWithOthers` out of `options` if it builds its own configuration: long-form route sharing is for audio that owns the session, and `setCategory` can fail with it.

### The list and its edits

`items` is a mirror of your queue, in play order, and `currentIndex` points into it. The app owns the
order, shuffle included; call `replaceItems` whenever the queue changes, or the player plays a stale next item.

```swift
player.replaceItems(episodes, currentIndex: 1)   // current keeps playing if it is the same item
player.insert([third], at: 2)
player.move(from: 2, to: 0)
player.remove(at: 2)                              // removing the current plays its successor
player.skipToNext()
player.skipToPrevious()
player.seek(to: 90)                               // within the current item
player.seek(by: -15)                              // clamped to the item
player.seek(to: 10, itemAt: 0)                    // across items
player.rate = 1.5                                 // 0.25...4, pitch kept; pause is not rate 0
player.bufferedAhead                              // seconds of PCM written past the playhead; what the renderer takes, at most 30
player.volume = 0.5                               // 0...1, applied at once; a fade is a ramp from your timer
player.setProcessors([silenceGate, voiceBoost])   // AudioProcessors, as for Transport
player.stop()                                     // idle, session deactivated; play() starts again
player.prepare()                                  // from idle: load the current item at position, paused
```

`replaceItems` with a different current item behaves as `setItems`. `setItems` with an empty list is
`removeAll()`. `skipToNext` and `skipToPrevious` ignore `repeatMode == .one`.

### Observe it

```swift
struct NowPlayingBar: View {
    let player: Player<Episode>
    var body: some View {
        HStack {
            Button(player.playWhenReady ? "Pause" : "Play") { player.playWhenReady.toggle() }
            if player.state == .buffering { ProgressView() }
            if player.suppression == .interruption { Text("Paused by another app") }
            Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }),
                   in: 0...(player.duration ?? 1)).disabled(!player.isSeekable)
        }
    }
}
```

- **`state`** is `.idle` (nothing prepared, or stopped on an error), `.buffering` (waiting for audio: a load or
  seek not yet decoded, or decode behind; paused or not, as media3; set by the call itself, so it never
  describes the item before), `.ready` or `.ended` (the last item finished; `play()` restarts at 0).
  `isPlaying` is `state == .ready && playWhenReady && suppression == .unsuppressed`. Show a play button from
  `playWhenReady`, not from `isPlaying`, or the button flickers while buffering.
- **`position`** is what is heard, in seconds of the current item's media time, written on every pump
  while it changes. `duration` is nil until the item opens and whenever the source does not know it.
  `isSeekable` is the source's, known once it opens; a server transcode seeks with no `duration`.
  `isLive` is an opened item that neither seeks nor has a duration (ADR-0022).
- **`audioFormat`** (media3 `getAudioFormat()`) is the current item's sample rate and channel count as
  decoded, the format your processors are configured with for it: draw an EQ curve at its rate. It is nil
  until the item is heard, and changes when a join into the next item is heard, not when it is decoded
  ahead (ADR-0025). A format change within an item updates it when the change is heard.
- **A seek not made as asked** is reported as `seekAdjusted(_:requested:position:)`: a target
  clamped to `0...duration`, a seek an unseekable item refused (it stays put), or a source that landed
  elsewhere, as on a keyframe (sent after `seekLanded`). An unseekable item never fails for a seek.
- **`discontinuityCount`** changes when `position` jumps instead of playing on: a seek, skip, load,
  transition or repeat. Compare it to its last value to tell a jump from listening; a position saver counts
  deltas only while it is unchanged. It may move more than once for one call.

```swift
func watch() {
    withObservationTracking {
        _ = (player.state, player.position, player.discontinuityCount)
    } onChange: {
        Task { @MainActor in
            save(player.position)
            watch()
        }
    }
}
```

`events` is an `AsyncStream` of what state cannot carry. Each is sent once, in order, after the state
that caused it is written; the stream ends when the player is deallocated. An event about an item
carries a `PlayerEvent.ItemRef`: its `index` in `items` and the `item` itself, both as they were when it
was sent. The stream yields later, after any edit made meanwhile, so read `ref.item`, never
`player.items[ref.index]`, which may name another item or be out of range.

```swift
Task {
    for await event in player.events {
        switch event {
        case .itemTransition(let from, let to, let reason): break   // ItemRefs; .auto, .seek or .repeat
        case .itemFailed(let ref, let error): break                 // error.kind: .source, .output, .session
        case .seekLanded(let ref, let position): break              // the seek's audio reached the speaker
        case .seekAdjusted(let ref, let requested, let position): break  // clamped, refused or landed elsewhere
        case .recoveredPaused: break                                // see Errors and recovery
        case .playWhenReadyChanged(let value, let reason): break    // the player changed intent: .routeLost, .interruptionEnded, .endOfItem
        case .firstAudioRendered(let ref, let position): break      // first audio heard after a load, seek or transition
        case .bufferingStarted(let ref, let position): break        // a rebuffer while playing
        case .bufferingEnded: break                                 // ends the last bufferingStarted
        }
    }
}
```

For telemetry, `firstAudioRendered` is sent once the first audio after a load, seek (skips included) or
item transition is heard playing, so time to first audio is the time from your call to it; a paused load
counts until `play()`, and a resume sends none. `bufferingStarted` and `bufferingEnded` bracket a
rebuffer: waiting for audio after the first was heard, while `playWhenReady` is set. A pause, seek, load,
stop, failure or item transition ends one (its `bufferingEnded` comes before the `itemTransition`), and
nothing is sent while paused, so a stall watchdog arms on the start and disarms on the end (ADR-0028).

### Repeat and pause at the end of an item

`repeatMode` is `.off`, `.all` (wraps from the last item to the first) or `.one` (the same entry again,
gapless). `pauseAtEndOfItem = true` is a sleep timer's "end of episode": when the current item finishes
the player sets `playWhenReady` to false and stays on the finished item, `.ready` with `position` at its
end, as media3's `pauseAtEndOfMediaItems` does; `play()` then moves on to the next item
(`itemTransition(.auto)`). Key on `playWhenReadyChanged(false, reason: .endOfItem)`: it is sent once, at
that pause. On the last item it ends. It also stops the next item being armed early; set within the last
seconds of an item, after decode has reached the next, the player still pauses at the end of the item.

### Errors and recovery

- **A failed item stops the player.** The state is `.idle` on that item with `error` set, `itemFailed`
  is sent, the audio session is released, and nothing skips ahead: your policy (skip up to N, show an
  alert) lives in one `itemFailed` handler, which calls `skipToNext()` if it wants to. `play()` retries
  from `position`; `prepare()` loads the current item there without playing, as media3's `prepare()`
  does, so a skip while paused shows the next item `.ready`.
- **A next item that fails** while the current one plays does not interrupt it. It is reported once
  playback reaches it, after its `itemTransition`, and never if you removed it first.
- **A session failure** (activation refused) sets `error.kind == .session` and leaves `playWhenReady` true, so
  the next `play()` tries again.
- **Recovery lands paused.** A renderer failure or a media-services reset is rebuilt once by the
  transport; the player sets `playWhenReady` to false, clears `suppression`, and sends `recoveredPaused`
  without a `playWhenReadyChanged`. Position is where it was. There is no auto-resume: call `play()` if
  the user was playing. A second failure is an `itemFailed`.

### The audio session

The player owns the session; the app does not observe interruptions or route changes for playback.

- **Interruption began** (call, Siri, another app) while playing: `suppression == .interruption`, the
  transport is paused, `playWhenReady` stays true. Paused or stopped, nothing happens, so a stopped
  player never shows "paused by another app".
- **Interruption ended** with `shouldResume`: the session is activated, playback resumes, `suppression`
  clears. If the activation is refused, `suppression` clears anyway and `error.kind == .session` is set
  (see recovery above); the next `play()` tries again. Without `shouldResume`: `playWhenReady` becomes
  false (reason `.interruptionEnded`). If the user pressed pause during the interruption, nothing resumes. A `play()` during an interruption takes the session back at once.
- **Route lost.** Unplugging headphones, or losing Bluetooth, USB, line out, a car or AirPlay with none of
  that kind left, pauses (`playWhenReady` false, reason `.routeLost`). A Bluetooth profile switch does not.
  A new device does nothing: auto-play on connect is an app preference.
- **Media-services reset**: the category is set again and the next `play()` activates; see recovery above.
- An app `seek` or `skipToNext` during an interruption is applied paused.

### Test it

`PlaybackPlayerTestSupport` runs the whole player with no device; see
[Test code built on `Player`](#test-code-built-on-player) for the rig and
`Tests/PlaybackPlayerExternalConsumerTests/CoordinatorTests.swift` for a test to copy.

## Show a `Player` on the lock screen

`PlaybackNowPlaying` binds a `Player` to `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`. Keep one
session for the app's life, since both centres are global:

```swift
let nowPlaying = NowPlayingSession(
    player: player,                                    // or a wrapper of it, below
    supportedRates: [1, 1.5, 2],                       // empty leaves the rate command off
    metadata: { episode in NowPlayingMetadata(title: episode.title, artist: episode.show, duration: episode.duration) },
    artwork: { episode in await artworkCache.artwork(for: episode) }   // MPMediaItemArtwork?
)
```

The metadata closure runs once per item change; its `duration` is shown until the player has opened the
item. Artwork that arrives after the item changed is dropped. Call `refreshMetadata()` after the app edits
the playing item's tags: it asks the metadata and artwork closures again and republishes title, artist,
album, artwork and duration, leaving elapsed time, rate and commands alone. Elapsed time and rate are written on a seek,
a play or pause, a rate change and an item change, never on each position update: the system
extrapolates between them. They are written again if what is heard strays more than 0.05 s from that
extrapolation, as when the output starts late after a play. A remote command is enabled only while the
player's `availableCommands` has it. A `Player`'s are media3's: next while there is a next item (repeat
`.all` wraps), previous on any item but a live one with nothing before it (with nothing before, it
restarts the item), skips and scrubbing once the item has opened seekable, play and pause always. An
item of unknown length that seeks is not shown live and shows the metadata's duration, if any.
`release()` disables every command and clears the info, the playback rates and the skip intervals.

**Your own policy.** The session drives `NowPlayingControllable`, as a media3 session drives a
`ForwardingPlayer`. Wrap the player with `ForwardingNowPlayingControllable` (with `PlayerCommands` and
`SkipIntervals`, it is in `PlaybackPlayer`, not `PlaybackNowPlaying`) and declare only what your
policy changes; everything else forwards. Make the wrapper `@Observable` so the session sees its changes:

```swift
@MainActor @Observable
final class SessionPlayer: ForwardingNowPlayingControllable {
    @ObservationIgnored let player: Player<Episode>
    var queueLocked = false
    init(player: Player<Episode>) { self.player = player }

    // A command left out is greyed out on the lock screen.
    var availableCommands: PlayerCommands {
        queueLocked ? player.availableCommands.subtracting([.seekToNext, .seekToPrevious]) : player.availableCommands
    }
    // Non-nil shows skip buttons in place of next and previous, which stay registered for
    // steering wheels and headphones; re-read on every item change.
    var skipIntervals: SkipIntervals? {
        player.currentItem?.isSpokenWord == true ? SkipIntervals(forward: 30, backward: 15) : nil
    }
    func seekToNext() { queue.advance(player) }   // the next button, through the app's queue rules
}
```

The next button calls `seekToNext()`, previous `seekToPrevious()` (the previous item, or a restart with
none), the skip buttons `seek(by:)`, the scrubber `seek(to:)`, the rate command `rate`'s setter, and play,
pause and toggle `play()` and `pause()`. Each is where the app takes the command over: declare it on the
wrapper to persist a speed, log analytics or seek its own way, and call `player` for the default.

**Test it.** `PlaybackNowPlayingTestSupport` builds the session on a `FakeNowPlayingInfoCenter` and a
`FakeRemoteCommandCenter`, with `now:` as its clock: pass `infoCenter:`, `commandCenter:` and `now:` to
`NowPlayingSession`'s initialiser. After driving the player, `await session.settle()` before reading
`info[MPMediaItemPropertyTitle]`, `info.playbackState`, `commands.enabled`, `commands.intervals` or
`commands.rates`; `commands.press(.pause)` runs a command as the lock screen would. See
`Tests/PlaybackPlayerExternalConsumerTests/NowPlayingTests.swift`.

## Write a byte source of your own

Conform to `StreamByteReader`: `read` blocks until at least one byte, returning 0 only at end of
stream; `totalLength` is nil when unknown, never a guess (a made-up length breaks MP4 with a trailing
`moov`); `cancel()` and `interrupt()` unblock a waiting call from any thread.

## Test code built on the streaming source

`PlaybackStreamingTestSupport` has `LoopbackMediaServer`, a `Range`-aware local HTTP server with fault
knobs (dropped connections, stalls, refusals, redirects, ignored `Range`). It has no audio fixtures;
supply your own.

```swift
let server = try LoopbackMediaServer(body: audioData, mimeType: "audio/mpeg")
let source = GrowingFileByteSource(url: server.url, authHeaders: [:], store: .temporary())
server.closesAfterBodyBytes = 40_000   // drop the first connection part-way
```

## Test code built on `Transport`

`PlaybackRenderTestSupport` runs a `Transport` with no renderer and no wall clock, for an app's tests of its
own player layer (queue advance, Now Playing, interruptions). Build it on a `FakeAudioOutput`, a
`ManualPumpTimer` and a `ManualExecutor` with `Transport(output:timer:executor:onEvent:)`, set items
with `FakeItemSource`, then step it: `timer.sync()`, `executor.runUntilIdle()`, `timer.fire()`, and
`output.advance(by:)` to move the clock. The output also injects auto-flushes, stalls and failures, and
records what was heard. It needs no SPI import or `@testable`; see
`Tests/PlaybackRenderTests/ExternalConsumerTests.swift`.

## Test code built on `Player`

`PlaybackPlayerTestSupport` drives a `Player<Item>` with no device, no `AVAudioSession` and no wall clock.
`PlayerTestRig<Item>` builds the player on a `FakeAudioOutput`, a `ManualPumpTimer` and a `ManualExecutor`
from your source factory, with a `FakeAudioSession` as `rig.session`. Step it with `rig.pump()`,
`rig.run(for:)` and `rig.settle()`; post `session.interruptionBegan()`,
`interruptionEnded(shouldResume:)` and `mediaServicesReset()`, and read `session.activations` and
`session.calls`. Only a route-change test needs `@_spi(Testing) import PlaybackPlayer`, for
`routeChanged(reason:previous:current:)`'s types. See
`Tests/PlaybackPlayerExternalConsumerTests/CoordinatorTests.swift` for a coordinator test to copy.

`FakeItemFactory<Item>` is a source factory scripted per item: thrown by the factory (`failing`), at
`open` (`unopenable`), at a seek (`failingSeeks`) or past a frame (`failingAtFrame`); ending early while
declaring its full length (`endingAtFrame`); live, seekable of unknown length or unseekable; and held in
`open` or a read by a `SourceStall` until `release()` or an interrupt. `factory.calls` lists the items
asked for. `rig.onEvent` sees each `PlayerEvent` as it is sent; `rig.finish()` returns them all.
`Tests/PlaybackPlayerExternalConsumerTests/ScriptedItemTests.swift` shows each.

## Testing your app against the test-support products

### Linking

Adding AudioPlaybackKit to an app's test target as well as the app makes Xcode link the package's
targets as dynamic frameworks. These ignore the project's `EXCLUDED_ARCHS[sdk=iphonesimulator*]`, so the
generic simulator build includes x86_64. The FFmpeg xcframework has no x86_64 simulator slice, so the
link fails with undefined `CStreamDecode` symbols. Build for arm64 only: pass `ARCHS=arm64` on the
`xcodebuild` line (or `ONLY_ACTIVE_ARCH=YES`). Shuttle2 also re-exports the test-support products
through a local package of its own, so its test targets depend on one package.

### Failing sources

Set the knobs before the player asks for the item. Each is keyed by item; `Episode` is your `Item` type.

```swift
let factory = FakeItemFactory<Episode>()
let rig = PlayerTestRig { try factory.make($0) }

factory.failing = [Episode(id: 1)]          // make() throws, as an item that cannot be resolved
factory.unopenable = [Episode(id: 2)]       // open() throws, as a dead URL does
factory.failingAtFrame = [Episode(id: 3): 40]   // throws once decode passes frame 40 (5 s at the default 8 Hz)
factory.failingSeeks = [Episode(id: 4)]     // throws on any seek that would move; a seek to the current frame succeeds
```

All of them throw `FakeItemError<Episode>(item:)`. `rig.player.error?.kind` is `.source` for the player
failures; `factory.calls` shows which items were asked for.

To hold a source instead of failing it, give it a `SourceStall`. `frame: nil` holds `open()`; a frame
holds the first read at or past it. It blocks once. Wait on `entered`, then `release()` it, or interrupt
the player's call.

```swift
let stall = SourceStall(frame: nil)
factory.stalls = [Episode(id: 1): stall]
rig.player.setItems([Episode(id: 1)])
rig.player.play()
// stall.entered.wait() once decode is blocked in open()
stall.release()
```

### Now Playing

`PlaybackNowPlayingTestSupport` has `FakeNowPlayingInfoCenter` (`nowPlayingInfo`, `playbackState`,
`writes`, and a subscript by key) and `FakeRemoteCommandCenter` (`enabled`, `intervals`, `rates`, and
`press(_:)` to run a command as the lock screen would). Pass them to `NowPlayingSession` with a `now:`
clock, and `await session.settle()` after driving the player, before reading them. See
[Show a `Player` on the lock screen](#show-a-player-on-the-lock-screen).
