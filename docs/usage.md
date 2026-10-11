# Usage

From adding the package to decoding a file and playing a URL while it downloads. Signatures and
parameters are in the doc comments of the types named here; this page covers the order of calls and the
behaviour you must know. Threading and blocking apply throughout: `open()`, `nextChunk()`,
`read(into:maxFrames:)` and `seek(toSeconds:)` block, so run them on a thread of your own, one thread per decoder.

## Add the package

```swift
dependencies: [
    .package(url: "https://github.com/timusus/AudioPlaybackKit.git", from: "0.9.0"),
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

MP3, AAC (ADTS and LATM), MP4/M4A (AAC, ALAC), Ogg (Vorbis, Opus, FLAC), Matroska/WebM (Opus, Vorbis), FLAC, PCM WAV/AIFF.

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

`open()` throws `StreamDecoderError`; a format the build lacks arrives as `.failed(status:)`. The probe
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
  Without it the source and its partial file leak.
- **Set `isProbing` around `open()`.** FFmpeg's MP3 open reads the last 128 bytes (an ID3v1 footer).
  While probing, that read answers end of file at once instead of cancelling the head download
  ([ADR-0003](decisions/0003-growing-file-playback.md)).
- **The decoder blocks while it waits for bytes.** That is how buffering shows up. The source retries
  drops itself; a read throws `StreamByteReaderError.transport` only when retries and the 30 s link
  window are spent, after the bytes already downloaded have been read. Play out what you have decoded,
  then show an error at that position.
- **Do not re-seek or recreate the source on a network change.** The source watches the network path and
  resumes from its frontier. A host that does the same races it
  ([ADR-0004](decisions/0004-one-recovery-layer-in-the-byte-source.md)).
- **Auth headers stay on the origin.** A redirect to another origin (a CDN) and its later restarts carry
  none of them.
- **Extra headers.** `GrowingFileConnectionPolicy.headers` adds request headers for the origin, with the same redirect rule as `authHeaders`.
- **Self-signed servers.** Pass `connectionPolicy: GrowingFileConnectionPolicy(trustedLeafSHA256: [...])`
  with the fingerprint the user trusted. It is an exception, not a pin: the system evaluates first,
  and only a certificate it refuses is accepted by fingerprint. Otherwise the read fails with
  `transport("untrusted_certificate")`, unretried.
- **Cache.** A download that completes from byte 0 is kept in a `GrowingFileStore` (default
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
  host shows it, fails the read at once with a `transport("out_of_range ...")`, with no retry.

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
refuses throws `StreamDecoderError.unseekable`, distinct from `.failed(status:)` (a corrupt stream),
whether or not the reader knows its `totalLength`.
The decoder has failed after it: `endReason` is `.failure` and reads return nothing, so open a new
decoder over a seekable source. A seek that libavformat can serve from bytes it still holds succeeds.
A seek or read that fails on a source error (`.failed(status:)`, say a network still down) is not
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

## Show buffering and download state

`source.snapshot` is readable from any thread: `base`, `frontier`, `totalLength`, `isComplete`,
`downloadBytesPerSecond`, `fileURL`; `base` and `frontier` are the range on disk the reader is in,
and `isComplete` says it reaches the end. `readWaitingSince` is the source clock's time the decoder's read
parked for bytes (nil when none waits), and `now - readWaitingSince` is the stall. `onEvent` delivers changes without polling: `.readWaiting(since:)` when the decoder's read parks for bytes and `.readResumed` when it ends (once per stall, on the decoder's thread outside the source's lock), `.transaction` when a
response is accepted, `.download` at most once a second, `.seekLanded` when a seek was served from the
file already on disk. A host that wants protocol-shaped callbacks implements `GrowingFileListener` and
calls it from `onEvent`; the source does not take a listener. A listener reads the file back through
`fileURL`, so it never sees a byte the decoder did not have.

## Play through the render layer

`PlaybackRender` (depends on `PlaybackDecode`) replaces an `AVAudioEngine` graph with one `Transport`
([ADR-0018](decisions/0018-render-layer.md)). It owns the `AVSampleBufferAudioRenderer` and its
synchronizer, keeps about two seconds of PCM written ahead of the playhead, joins items gaplessly, and
reports what is heard. The app keeps the `AVAudioSession` (category, activation, interruptions), Now
Playing and remote commands, the queue, and the effects. The transport never touches the session: set
the category and activate it before `play()`.

```swift
import PlaybackRender

let transport = Transport<Track.ID> { event in          // called on the transport's queue
    switch event {
    case .position(let id, let seconds, let duration): break   // media time of `id`; duration nil when unknown
    case .crossed(let id): break                        // `id` is now heard; advance your queue
    case .status(let status): break                     // .paused, .buffering, .playing, .ended
    case .sought(let id, let seconds, let applied): break  // a setCurrent or seek was taken; if applied, events before it are stale
    case .failed(let id, let error): break              // paused, unless `id` is a next item not yet heard
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
in seconds as FFmpeg probed it, nil for a live stream or a body of unknown length. `.ended` is not final, a later `setNext` plays on.
`setCurrent` replaces everything set, so it is also how a skip or a track change by the user works.
A source belongs to one `setCurrent` or `setNext`; make a new `FFmpegItemSource` each time.

**Gapless.** Call `setNext(item:source:)` for the track after the current one as soon as the app
knows it, and again when the queue changes (the last next item is replaced if decode has not reached it;
`clearNext()` removes it). Items of different sample rates join in one stream. `.crossed` says when the
speaker reached the new item.

**Effects.** Skip-silence, Voice Boost, ReplayGain, EQ and limiters are `AudioProcessor`s passed to
`setProcessors(_:)`. They run on interleaved Float32 PCM on the transport's queue, in order, and
may drop frames (`ProcessorOutput.dropped`, so positions stay in media time) but never add them. A
processor cannot change the sample rate; `configure(_:)` receives the item's format, so a filter that
depends on the rate (an EQ) derives its coefficients there and again after each `flush()`. Adding or
removing a processor, changing its `isActive` or changing its output format needs another
`setProcessors` call, which never flushes: the old chain drains into the queued audio and the new
one takes over at the next chunk. A processor's own parameters (a gain, EQ bands, or an "enabled"
flag it reads inside a stage that stays `isActive`) apply live, read under its own lock.

**Processed PCM is heard about one feed depth later.** A change a processor makes at "now", or a new
chain from `setProcessors`, reaches the speaker roughly two seconds on, without a gap. Fades,
ducks and mutes therefore go through `setVolume`, which acts at once: the app calls it repeatedly
from its own timer or display link.

**Failure.** A failed renderer or a media-services reset is recovered once: the transport rebuilds
the output and lands paused at the same position, and the app calls `play()` again. A second failure
surfaces as `.failed`, and `play()` does nothing until a `seek`, `setCurrent` or `setProcessors`.
A source or processor error that stops an item also arrives as `.failed(item:error:)`. When the item
is a next one decode reached early, it is dropped and the current item plays on without a pause, so
the app chooses what follows; the heard item's failure pauses.

### Moving an app over

The order of work, a concept map and a device checklist for each app are in [migrating.md](migrating.md).

Shuttle Podcasts:

- The streaming PCM reader becomes `FFmpegItemSource(reader: GrowingFileByteSource(...))`.
- The silence gate, Voice Boost and the Smart Skip mixer become `AudioProcessor`s. Report the frames a
  gate drops in `dropped` so the position and the ad-skip arithmetic stay in media time.
- Fades and ducks use `setVolume`, not a processor.
- Keep the `AVAudioSession` handling and Now Playing; feed them from `.position` and `.status`.

Shuttle2:

- ReplayGain, the EQ and the limiter become `AudioProcessor`s. The EQ computes its coefficients from
  the sample rate given to `configure(_:)`, never from a fixed 44.1 kHz.
- Call `setNext` with the next track as the queue changes; delete the pre-open and underrun code, the
  transport joins items and rides through an underrun itself.
- There is no crossfade: the join is gapless. Fades at a track end are `setVolume` ramps.

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
