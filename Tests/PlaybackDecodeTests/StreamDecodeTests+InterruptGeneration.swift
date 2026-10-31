import Foundation
import XCTest
@testable import PlaybackDecode

/// An interrupt aimed at a generation must survive the clear at the start of that generation's own
/// seek, and one aimed at an earlier generation must not stop a later call.
extension StreamDecodeTests {
    /// The interrupt lands before the seek starts, which is the earliest "just before the clear" can
    /// be. The reader ignores interrupts, so only the decoder's own flag can end the seek.
    func testAnInterruptAimedAtASeekBeforeItStartsEndsIt() throws {
        try skipUnlessAvailable()
        let decoder = FFmpegStreamDecoder(reader: InterruptDeafByteReader(try FileByteReader(url: try Fixture.url(Fixture.mp3))))
        try decoder.open()
        decoder.begin(generation: 1)
        decoder.interrupt(through: 1)

        XCTAssertThrowsError(try decoder.seek(toSeconds: 5)) { error in
            XCTAssertEqual(error as? StreamDecoderError, .interrupted)
        }
        XCTAssertEqual(decoder.endReason, .interrupted)
    }

    /// The same through the reader's flag, which a seek clears first.
    func testAnInterruptAimedAtASeekBeforeItStartsEndsItThroughTheReader() throws {
        try skipUnlessAvailable()
        let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: try Fixture.url(Fixture.mp3)))
        try decoder.open()
        decoder.begin(generation: 1)
        decoder.interrupt(through: 1)

        XCTAssertThrowsError(try decoder.seek(toSeconds: 5)) { error in
            XCTAssertEqual(error as? StreamDecoderError, .interrupted)
        }
    }

    /// An interrupt that reached only the reader while the open ran still ends the generation's seek.
    func testAnInterruptAimedAtAnOpenAlsoEndsTheSeekAfterIt() throws {
        try skipUnlessAvailable()
        let decoder = FFmpegStreamDecoder(reader: InterruptDeafByteReader(try FileByteReader(url: try Fixture.url(Fixture.mp3))))
        decoder.begin(generation: 1)
        decoder.interrupt(through: 1)
        try decoder.open()

        XCTAssertThrowsError(try decoder.seek(toSeconds: 5)) { error in
            XCTAssertEqual(error as? StreamDecoderError, .interrupted)
        }
    }

    func testAnInterruptAimedAtAnEarlierGenerationLetsTheSeekRun() throws {
        try skipUnlessAvailable()
        let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: try Fixture.url(Fixture.mp3)))
        try decoder.open()
        decoder.begin(generation: 1)
        decoder.interrupt(through: 1)
        decoder.begin(generation: 2)

        let landed = try decoder.seek(toSeconds: 5)
        XCTAssertEqual(landed, 5, accuracy: 0.001)
        XCTAssertEqual(decoder.endReason, .running)
        XCTAssertNotNil(decoder.nextChunk())
    }

    /// Once the calls have moved on, an interrupt aimed at an earlier generation raises nothing.
    func testALateInterruptForAnEarlierGenerationIsIgnored() throws {
        try skipUnlessAvailable()
        let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: try Fixture.url(Fixture.mp3)))
        try decoder.open()
        decoder.begin(generation: 2)
        decoder.interrupt(through: 1)

        XCTAssertNotNil(decoder.nextChunk(), "an interrupt for generation 1 stopped a read of generation 2")
    }
}

/// Never interrupted itself, so a test sees only the decoder's own interrupt flag.
private final class InterruptDeafByteReader: StreamByteReader {
    private let inner: StreamByteReader

    init(_ inner: StreamByteReader) { self.inner = inner }

    var totalLength: Int64? { inner.totalLength }
    var position: Int64 { inner.position }

    func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
        try inner.read(into: buffer, maxLength: maxLength)
    }

    func seek(to offset: Int64) throws { try inner.seek(to: offset) }
    func cancel() { inner.cancel() }
    func interrupt() {}
    func clearInterrupt() {}
}
