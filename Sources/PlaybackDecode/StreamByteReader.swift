import Foundation

/// **Blocking, seekable byte access for the streaming decoder.**
///
/// The playback decoder drives FFmpeg through a custom `AVIOContext` whose read and seek
/// callbacks land here. ``FileByteReader`` reads a local file; `GrowingFileByteSource` in
/// `PlaybackStreaming` reads an HTTP(S) download as it grows; an app can bring its own. Nothing
/// above this protocol knows which one it has.
///
/// Every call runs on the decoder's own thread and may block: `read` waits for bytes to arrive,
/// `seek` may cancel and reopen a transport. `cancel()` and `interrupt()` are the calls made from
/// another thread; each must unblock a waiting `read` or `seek`, which then throws
/// ``StreamByteReaderError/cancelled`` or ``StreamByteReaderError/interrupted``.
public protocol StreamByteReader: AnyObject {

    /// Total length in bytes, or nil while unknown. FFmpeg asks for it (`AVSEEK_SIZE`) to reach a
    /// trailing `moov` with one seek instead of read-discarding the whole `mdat`.
    var totalLength: Int64? { get }

    /// Absolute offset the next `read` returns bytes from.
    var position: Int64 { get }

    /// Copy up to `maxLength` bytes at ``position`` into `buffer`, advance ``position`` by the
    /// count, and return it. Blocks until at least one byte is available. Returns 0 only at end of
    /// stream. Throws on cancellation or a transport failure it could not recover from.
    func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int

    /// Move ``position`` to `offset`. Throws ``StreamByteReaderError/unseekable`` when the source
    /// cannot serve that offset, or `cancelled`.
    func seek(to offset: Int64) throws

    /// Abort any blocked or future call. Idempotent; safe from any thread.
    func cancel()

    /// Bring the blocked call back so the caller can seek — **without ending the stream**.
    ///
    /// A player whose pull loop is waiting on a stalled connection cannot apply a seek until the
    /// read returns, and on a dead link it never does. Cancelling would answer the seek and destroy
    /// the reader; this leaves it usable, and ``clearInterrupt()`` (which the decoder calls as part
    /// of its next seek) puts it back to work. Idempotent; safe from any thread.
    func interrupt()

    /// Forget an interruption. Called by the decoder before the seek that follows one.
    func clearInterrupt()

    /// End (exclusive) of the bytes from ``position`` on that are already held locally, so a read
    /// up to it never waits on a transport. The decoder then seeks to a target past it rather than
    /// reading forward to it, letting the reader fetch from there. Nil, the default, when every
    /// byte is local (a file) or when reading on is the only way to reach bytes ahead.
    var fetchedEnd: Int64? { get }
}

public extension StreamByteReader {
    var fetchedEnd: Int64? { nil }
}

public enum StreamByteReaderError: Error, Equatable, Sendable {
    case cancelled
    /// The call was ended early by ``StreamByteReader/interrupt()``. Recoverable: unlike
    /// `cancelled` the reader may be read from again after ``StreamByteReader/clearInterrupt()``.
    case interrupted
    case unseekable
    /// The source could not deliver: `.io` for local storage, `.network` or `.http` for a transport,
    /// `.unsupported` for a page served where audio should be. The decoder passes it on unchanged.
    case failed(StreamFailure)

    public var category: PlaybackErrorCategory {
        switch self {
        case .cancelled: .cancelled
        case .interrupted: .internal
        case .unseekable: .unsupported
        case let .failed(failure): failure.category
        }
    }
}
