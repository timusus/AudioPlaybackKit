import Foundation

/// **Why playback of an item failed, grouped by what a caller does about it** (ADR-0029).
///
/// media3's `PlaybackException.errorCode` groups, cut to the answers an app has: retry or resume
/// (`network`, a `5xx`), refresh the URL (a `4xx`), skip or fall back to another player (`malformed`,
/// `unsupported`), or report a bug (`internal`).
public enum PlaybackErrorCategory: Hashable, Sendable {
    /// Local storage: a file missing or unreadable, a disk full (media3 `IO_FILE_NOT_FOUND`,
    /// `IO_NO_PERMISSION`).
    case io
    /// The connection failed, dropped or went silent, and the byte source's retries are spent
    /// (media3 `IO_NETWORK_CONNECTION_FAILED`, `_TIMEOUT`). Worth a retry once the network is back,
    /// unless ``StreamFailure/urlError`` is one no retry fixes (an untrusted certificate, a bad URL,
    /// ATS refusing cleartext): media3 gives those no code of their own either, bar cleartext.
    case network
    /// The server answered with `status` until the retries were spent (media3 `IO_BAD_HTTP_STATUS`).
    case http(status: Int)
    /// A format this build reads, but the bytes are damaged or cut short (media3
    /// `PARSING_CONTAINER_MALFORMED`, `DECODING_FAILED`, `IO_READ_POSITION_OUT_OF_RANGE`).
    case malformed
    /// Not something this build plays: no demuxer or decoder for it, no audio in it, a source that
    /// cannot seek, or a page where audio should be (media3 `PARSING_CONTAINER_UNSUPPORTED`,
    /// `DECODING_FORMAT_UNSUPPORTED`, `IO_INVALID_HTTP_CONTENT_TYPE`).
    case unsupported
    /// The source was cancelled under the item; not a fault in it.
    case cancelled
    /// A fault in this library or the app's own code (a processor, a misused API), an allocation
    /// failure, or an output or session error (media3 `UNSPECIFIED`, `FAILED_RUNTIME_CHECK`).
    case `internal`
}

/// **A source failure with its category and its cause**, thrown by a ``StreamByteReader`` as
/// ``StreamByteReaderError/failed(_:)`` and by the decoder as ``StreamDecoderError/failed(_:)``.
/// A reader's failure reaches the decoder's caller as the same value, with the AVERROR it caused.
public struct StreamFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public var category: PlaybackErrorCategory
    /// FFmpeg's `AVERROR` behind a decoder failure, when libav reported one.
    public var averror: Int32?
    /// The transport's error, when the request failed with one.
    public var urlError: URLError?
    /// For logs only: what failed, in the layer's own words.
    public var detail: String

    public init(_ category: PlaybackErrorCategory, detail: String, averror: Int32? = nil, urlError: URLError? = nil) {
        self.category = category
        self.detail = detail
        self.averror = averror
        self.urlError = urlError
    }

    public var description: String {
        var text = "\(category): \(detail)"
        if let averror { text += " averror=\(averror)" }
        if let urlError { text += " url_error=\(urlError.code.rawValue)" }
        return text
    }
}
