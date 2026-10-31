import Foundation
import XCTest
@testable import PlaybackDecode

/// Delivers normally until ``arm()``, then parks every read until interrupted or cancelled: the
/// host going quiet while a seek is reading.
private final class ParkOnceArmedReader: StreamByteReader {
    private let inner: FileByteReader
    private let gate = NSCondition()
    private var armed = false
    private var interrupted = false
    private var cancelled = false
    private var parked = false

    init(url: URL) throws { inner = try FileByteReader(url: url) }

    var totalLength: Int64? { inner.totalLength }
    var position: Int64 { inner.position }

    func arm() { gate.withLock { armed = true } }

    func disarm() { gate.withLock { armed = false; gate.broadcast() } }

    func waitUntilParked(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        gate.lock(); defer { gate.unlock() }
        while !parked, gate.wait(until: deadline) {}
        return parked
    }

    func read(into buffer: UnsafeMutableRawPointer, maxLength: Int) throws -> Int {
        gate.lock()
        while armed, !interrupted, !cancelled {
            parked = true
            gate.broadcast()
            gate.wait()
        }
        parked = false
        let (stopped, brought) = (cancelled, interrupted)
        gate.unlock()
        if stopped { throw StreamByteReaderError.cancelled }
        if brought { throw StreamByteReaderError.interrupted }
        return try inner.read(into: buffer, maxLength: maxLength)
    }

    func seek(to offset: Int64) throws { try inner.seek(to: offset) }

    func cancel() {
        gate.withLock { cancelled = true; gate.broadcast() }
        inner.cancel()
    }

    func interrupt() { gate.withLock { interrupted = true; gate.broadcast() } }

    func clearInterrupt() { gate.withLock { interrupted = false; gate.broadcast() } }
}

extension StreamDecodeTests {

    // MARK: - A seek that is ended

    private func openArmable() throws -> (FFmpegStreamDecoder, ParkOnceArmedReader) {
        let reader = try ParkOnceArmedReader(url: try Fixture.url(Fixture.mp3))
        let decoder = FFmpegStreamDecoder(reader: reader)
        _ = try decoder.open()
        XCTAssertNotNil(decoder.nextChunk())
        return (decoder, reader)
    }

    /// `open()` already has these two; a seek is the call a player makes on a dead link.
    func testASeekAfterCancelThrowsCancelled() throws {
        try skipUnlessAvailable()
        let (decoder, _) = try openArmable()
        decoder.cancel()

        XCTAssertThrowsError(try decoder.seek(toSeconds: 15)) {
            XCTAssertEqual($0 as? StreamDecoderError, .cancelled)
        }
        XCTAssertEqual(decoder.endReason, .cancelled)
    }

    func testACancelWhileASeekIsReadingThrowsCancelled() throws {
        try skipUnlessAvailable()
        let (decoder, reader) = try openArmable()
        reader.arm()
        let result = ResultBox()
        let done = expectation(description: "the seek returned")
        DispatchQueue.global().async {
            result.set(Result { try decoder.seek(toSeconds: 15) })
            done.fulfill()
        }
        XCTAssertTrue(reader.waitUntilParked(timeout: 5), "the seek never reached the stall")
        decoder.cancel()
        wait(for: [done], timeout: 5)

        guard case .failure(let error) = result.value else { return XCTFail("the seek returned \(String(describing: result.value))") }
        XCTAssertEqual(error as? StreamDecoderError, .cancelled)
        XCTAssertEqual(decoder.endReason, .cancelled)
    }

    func testAnInterruptWhileASeekIsReadingThrowsInterruptedAndTheNextSeekRuns() throws {
        try skipUnlessAvailable()
        let (decoder, reader) = try openArmable()
        reader.arm()
        let result = ResultBox()
        let done = expectation(description: "the seek returned")
        DispatchQueue.global().async {
            result.set(Result { try decoder.seek(toSeconds: 15) })
            done.fulfill()
        }
        XCTAssertTrue(reader.waitUntilParked(timeout: 5), "the seek never reached the stall")
        decoder.interrupt()
        wait(for: [done], timeout: 5)

        guard case .failure(let error) = result.value else { return XCTFail("the seek returned \(String(describing: result.value))") }
        XCTAssertEqual(error as? StreamDecoderError, .interrupted, "never .failed: a caller answers that with its fallback")
        XCTAssertEqual(decoder.endReason, .interrupted)

        // The seek the interrupt was for runs on the same decoder, once the host answers.
        reader.disarm()
        XCTAssertEqual(try decoder.seek(toSeconds: 5), 5, accuracy: 1.0)
        XCTAssertEqual(decoder.endReason, .running)
        XCTAssertNotNil(decoder.nextChunk())
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Result<TimeInterval, Error>?
    var value: Result<TimeInterval, Error>? { lock.withLock { _value } }
    func set(_ value: Result<TimeInterval, Error>) { lock.withLock { _value = value } }
}
