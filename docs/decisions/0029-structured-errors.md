# ADR-0029: Failures carry a category, from the byte source to the player

Status: Accepted
Date: 2026-10-13

## Context

An app decides on a failed item whether to retry, refresh its URL, skip it or report a bug (#105). The
decoder threw `failed(status:)` with a `-1` for every libav error, the byte source threw
`transport(String)`, and `PlaybackError` wrapped either as `any Error`. A connection lost during the probe
came out as "no demuxer recognised the stream", so a network blip looked like an unplayable file, and
apps matched on strings.

## Decision

One `PlaybackErrorCategory`, the groups of media3's `PlaybackException.errorCode` cut to the answers an
app has: `io`, `network`, `http(status:)`, `malformed`, `unsupported`, `cancelled`, `internal`. It rides on
one `StreamFailure` (category, `detail` for logs, `averror`, `urlError`), thrown as
`StreamByteReaderError.failed(_:)` by a source and `StreamDecoderError.failed(_:)` by the decoder.
`PlaybackError.category` reads it off the underlying error; anything the library did not raise is
`internal`.

- **The C layer keeps the AVERROR.** Every libav failure (open, codec open, read, seek) records it in the
  decoder (`last_averror`, and an out-parameter on open), so the Swift failure carries the real code
  instead of `-1`.
- **A reader's failure wins over the C status.** The read callback records what the reader threw, and the
  decoder reports that failure (with the AVERROR it caused) rather than mapping the status, so a network,
  HTTP or disk failure keeps its category whatever libavformat made of it. libavformat reads ahead and
  surfaces a read error a call later, so the record survives successful reads and is cleared when a failure
  consumes it or an open or a seek restarts reading. `setOutput` never consults it. It is touched only on the
  thread inside a C call, so it needs no lock.
- **The C status maps as media3's extractors do**: no demuxer, no audio, no codec at open or no conversion
  is `unsupported`; undecodable frames, or a demuxer read or seek failure on bytes the reader delivered, is
  `malformed`; allocation is `internal`.
- **The byte source names its own failures**: every way the connection fails is `network` (with the
  `URLError`), an HTTP status after the retries is `http(status:)`, a page where audio should be is
  `unsupported`, a range the server says is past the end (416) is `malformed` (media3
  `IO_READ_POSITION_OUT_OF_RANGE`), and a disk failure is `io`. An app's reader that throws anything
  else is `io`, or `network` for a `URLError`.
- **`network` includes the errors no retry fixes** (untrusted certificate, bad URL, ATS refusing cleartext).
  media3 folds SSL and URL failures into `IO_NETWORK_CONNECTION_FAILED` and has a separate code only for
  cleartext; no app here answers cleartext differently from a bad URL, so there is no new category. The
  source does not retry them, and the `urlError` on the failure tells them from a lost connection.

`malformed` rarely comes from the decoder. FFmpeg drops a corrupt frame and ends a truncated file or a run
of garbage at EOF, as media3 does, and the pump skips `avcodec_send_packet` errors; so honest bytes do not
force it, and the per-category test at `itemFailed` pins it through the byte source's pass-through.

## Alternatives rejected

- media3's full error-code list: dozens of codes no app branches on differently; `detail` and `averror`
  keep the precision for logs.
- A category per layer (a decoder enum, a source enum, a player enum): an app would map three, and a
  reader failure would still be re-labelled at each crossing.
- Mapping the reader's failure from the AVERROR it caused: `AVERROR(EIO)` says nothing of network versus
  disk.

## Consequences

`StreamDecoderError.failed(status:)` and `StreamByteReaderError.transport(_:)` are gone (a minor bump at
0.x); [migration-errors](../migration-errors.md) lists every change. A reader failure swallowed by a
read-ahead can still be attributed to a later C failure before the next seek, which names the right
cause in practice; a successful read cannot tell a buffered-frames return from a recovery. A seek that fails on a ladder step but lands on a fallback clears its AVERROR.

Links: issue #105, `StreamDecodeErrorCategoryTests`, `PlayerErrorCategoryTests`, ADR-0004, ADR-0019.
