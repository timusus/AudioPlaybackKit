import Foundation
import XCTest

@testable @_spi(Testing) import PlaybackDecode

/// `wavpack_stereo.wv`: 4 s at 44.1 kHz in eight blocks of about 25 KB. The wv demuxer has no seek of
/// its own and cannot find a block from an arbitrary byte, so a seek further in than the budget's
/// walk anchors on a block whose header the decoder found.
final class WavPackSeekTests: XCTestCase {
    private let url = GoldenStore.fixturesDir.appendingPathComponent("wavpack_stereo.wv")

    private func decodeAll(_ decoder: FFmpegStreamDecoder) -> [Float] {
        var pcm: [Float] = []
        while let chunk = decoder.nextChunk() { pcm += chunk }
        return pcm
    }

    /// **A seek past the budget's walk lands on the sample asked for, with the stream's PCM.**
    ///
    /// Every target is more than 64 KiB of blocks in, where the byte estimate left the demuxer
    /// mid-block and the seek failed on the next read. 3.9 s is in the last block, whose start
    /// (byte 182 132) is before the target's byte estimate. The seek reads at most two probes of a
    /// block and its successor, then the landing's two blocks and an AVIO refill: under the 180 KB
    /// before the last block that the demuxer's walk reads, so a block header anchored it.
    func testSeeksPastTheBudgetLandSampleExactly() throws {
        try XCTSkipUnless(FFmpegStreamDecoder.isAvailable, "no FFmpeg in this build")
        let clean = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
        _ = try clean.open()
        let reference = decodeAll(clean)
        XCTAssertEqual(reference.count, 176_400 * 2)
        let largestBlock: Int64 = 27_248
        let bound = 6 * largestBlock + 32 * 1024

        for target in [1.5, 8.0 / 3.0, 3.9] {
            let reader = try FaultyByteReader(url: url)
            let decoder = FFmpegStreamDecoder(reader: reader)
            _ = try decoder.open()
            let before = reader.bytesRead
            let landed = try decoder.seek(toSeconds: target)
            XCTAssertLessThanOrEqual(reader.bytesRead - before, bound, "seek to \(target)")
            XCTAssertEqual(landed, target, accuracy: 1.0 / 44100, "seek to \(target)")
            let got = decodeAll(decoder)
            let start = Int((target * 44100).rounded()) * 2
            XCTAssertEqual(decoder.endReason, .eof, "seek to \(target)")
            XCTAssertEqual(got.count, reference.count - start, "seek to \(target)")
            XCTAssertTrue(got == Array(reference[start...]), "seek to \(target): PCM differs from the stream's")
        }
    }

    /// **With no length, the decode has every sample and ends at the end.**
    ///
    /// The end is FFmpeg's: without a size the wv demuxer cannot find the APE tag after the last
    /// block and reads it as a block header, which fails.
    func testUnknownLengthDecodesEverySampleThenEnds() throws {
        try XCTSkipUnless(FFmpegStreamDecoder.isAvailable, "no FFmpeg in this build")
        let clean = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
        _ = try clean.open()
        let reference = decodeAll(clean)

        let decoder = FFmpegStreamDecoder(reader: try FaultyByteReader(url: url, switches: .unknownLength))
        _ = try decoder.open()
        XCTAssertTrue(decodeAll(decoder) == reference, "PCM differs from the clean decode")
        XCTExpectFailure("FFmpeg's wv demuxer fails on the APE tag: https://github.com/timusus/AudioPlaybackKit/issues/175") {
            XCTAssertEqual(decoder.endReason, .eof)
        }
    }
}
