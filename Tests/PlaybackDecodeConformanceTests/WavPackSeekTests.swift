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
    /// Both targets are more than 64 KiB of blocks in, where the byte estimate left the demuxer
    /// mid-block and the seek failed on the next read.
    func testSeeksPastTheBudgetLandSampleExactly() throws {
        try XCTSkipUnless(FFmpegStreamDecoder.isAvailable, "no FFmpeg in this build")
        let clean = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
        _ = try clean.open()
        let reference = decodeAll(clean)
        XCTAssertEqual(reference.count, 176_400 * 2)

        for target in [8.0 / 3.0, 3.9] {
            let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
            _ = try decoder.open()
            let landed = try decoder.seek(toSeconds: target)
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
