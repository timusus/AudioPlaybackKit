import CoreMedia
@testable @_spi(Testing) import PlaybackRender
import XCTest

/// The adapter's pure parts: timestamps, format descriptions and sample buffers. The renderer
/// itself is covered by `SampleBufferAudioOutputIntegrationTests`.
final class SampleBufferAudioOutputTests: XCTestCase {
    /// Stamps an hour of `chunkFrames`-frame chunks the way the feeder does (each at the map's
    /// written end) and returns the last chunk's timestamp, failing on any join that is not
    /// exactly one chunk after the one before.
    private func stampAnHour(sampleRate: Double, chunkFrames: Int64, from anchor: TimeInterval) -> CMTime {
        var map = MediaPositionMap()
        map.reset(at: anchor)
        var previous: CMTime?
        var mediaFrame: Int64 = 0
        while mediaFrame < Int64(3600 * sampleRate) {
            let pts = presentationTime(map.writtenEnd, sampleRate: sampleRate)
            if let previous, pts.value - previous.value != chunkFrames {
                XCTFail("join at media frame \(mediaFrame) is \(pts.value - previous.value) frames, not \(chunkFrames)")
                return pts
            }
            previous = pts
            map.append(SegmentTag(item: 1, mediaStartFrame: mediaFrame, frameCount: chunkFrames), sampleRate: sampleRate)
            mediaFrame += chunkFrames
        }
        return presentationTime(map.writtenEnd, sampleRate: sampleRate)
    }

    func testTimestampsAreFrameExactAfterAnHourAt44100() {
        let end = stampAnHour(sampleRate: 44100, chunkFrames: 1152, from: 0)
        XCTAssertEqual(end.timescale, 44100)
        // 3600 s of 1152-frame chunks rounds up to 137_813 chunks.
        XCTAssertEqual(end.value, 158_760_576)
    }

    func testTimestampsAreFrameExactAfterAnHourAt48000() {
        let end = stampAnHour(sampleRate: 48000, chunkFrames: 1024, from: 0)
        XCTAssertEqual(end.timescale, 48000)
        XCTAssertEqual(end.value, 172_800_000)
    }

    func testTimestampsAreFrameExactAfterAnHourAt22050() {
        let end = stampAnHour(sampleRate: 22050, chunkFrames: 576, from: 0)
        XCTAssertEqual(end.timescale, 22050)
        // 3600 s of 576-frame chunks rounds up to 137_813 chunks.
        XCTAssertEqual(end.value, 79_380_288)
    }

    func testTimestampsFromAClockAnchorOffAFrameRoundToTheNearestFrameAndStillJoinExactly() {
        // A re-anchor lands on whatever the clock read: 12.3456789 s is 544_444.44 frames at 44.1k.
        XCTAssertEqual(presentationTime(12.3456789, sampleRate: 44100).value, 544_444)
        let end = stampAnHour(sampleRate: 44100, chunkFrames: 4410, from: 12.3456789)
        XCTAssertEqual(end.value, 159_304_444)
    }

    func testAnAnchorReadsBackAtLeastTheTimeSet() {
        // A clock reading plus a quarter second of written audio, as the feeder pauses an underrun.
        let writtenEnd = 0.345083709 + 0.25
        XCTAssertEqual(anchorTime(writtenEnd).value, 595_083_710)
        XCTAssertGreaterThanOrEqual(anchorTime(writtenEnd).seconds, writtenEnd)
        // A clock reading is already whole nanoseconds and stays put.
        XCTAssertEqual(anchorTime(0.345083709).value, 345_083_709)
        XCTAssertEqual(anchorTime(10).value, 10_000_000_000)
    }

    func testFormatDescriptionIsPackedInterleavedFloat32() throws {
        let description = try makeFormatDescription(PCMFormat(sampleRate: 48000, channelCount: 2))
        let asbd = try XCTUnwrap(description.audioStreamBasicDescription)
        XCTAssertEqual(asbd.mSampleRate, 48000)
        XCTAssertEqual(asbd.mFormatID, kAudioFormatLinearPCM)
        XCTAssertEqual(asbd.mFormatFlags, kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)
        XCTAssertEqual(asbd.mFramesPerPacket, 1)
        XCTAssertEqual(asbd.mBytesPerFrame, 8)
        XCTAssertEqual(asbd.mBytesPerPacket, 8)
        XCTAssertEqual(asbd.mChannelsPerFrame, 2)
        XCTAssertEqual(asbd.mBitsPerChannel, 32)
        XCTAssertEqual(layoutTag(description), kAudioChannelLayoutTag_Stereo)
    }

    func testMonoFormatDescription() throws {
        let description = try makeFormatDescription(PCMFormat(sampleRate: 22050, channelCount: 1))
        let asbd = try XCTUnwrap(description.audioStreamBasicDescription)
        XCTAssertEqual(asbd.mSampleRate, 22050)
        XCTAssertEqual(asbd.mBytesPerFrame, 4)
        XCTAssertEqual(asbd.mChannelsPerFrame, 1)
        XCTAssertEqual(layoutTag(description), kAudioChannelLayoutTag_Mono)
    }

    /// Above stereo the decoder's PCM is in FFmpeg's default order for its count; each channel is
    /// labelled so a downmix or spatial render puts centre and LFE where they belong.
    func testMultichannelFormatDescriptionLabelsFFmpegsDefaultOrder() throws {
        let expected: [Int: [AudioChannelLabel]] = [
            3: [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_LFEScreen],
            4: [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_CenterSurround],
            5: [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
                kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround],
            6: [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
                kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround],
            7: [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
                kAudioChannelLabel_CenterSurround, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround],
            8: [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
                kAudioChannelLabel_RearSurroundLeft, kAudioChannelLabel_RearSurroundRight,
                kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround],
        ]
        for (channels, labels) in expected {
            let description = try makeFormatDescription(PCMFormat(sampleRate: 48000, channelCount: channels))
            let layout = try XCTUnwrap(CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: nil), "\(channels)")
            XCTAssertEqual(layout.pointee.mChannelLayoutTag, kAudioChannelLayoutTag_UseChannelDescriptions, "\(channels)")
            let first = UnsafeRawPointer(layout)
                .advanced(by: MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!)
                .assumingMemoryBound(to: AudioChannelDescription.self)
            let got = (0..<Int(layout.pointee.mNumberChannelDescriptions)).map { first[$0].mChannelLabel }
            XCTAssertEqual(got, labels, "\(channels)")
        }
        let nine = try makeFormatDescription(PCMFormat(sampleRate: 48000, channelCount: 9))
        XCTAssertEqual(layoutTag(nine), kAudioChannelLayoutTag_DiscreteInOrder | 9)
    }

    private func layoutTag(_ description: CMAudioFormatDescription) -> AudioChannelLayoutTag? {
        CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: nil)?.pointee.mChannelLayoutTag
    }

    func testSampleBufferCarriesEveryFrameAtItsTimestamp() throws {
        let description = try makeFormatDescription(PCMFormat(sampleRate: 48000, channelCount: 2))
        let samples = (0..<960).map(Float.init)
        let pts = CMTime(value: 96000, timescale: 48000)
        let buffer = try makeSampleBuffer(samples, description: description, presentationTime: pts)

        XCTAssertEqual(CMSampleBufferGetNumSamples(buffer), 480)
        XCTAssertEqual(buffer.presentationTimeStamp, CMTime(value: 96000, timescale: 48000))
        XCTAssertEqual(buffer.duration, CMTime(value: 480, timescale: 48000))
        XCTAssertTrue(buffer.formatDescription === description)
        var copied = [Float](repeating: -1, count: 960)
        let block = try XCTUnwrap(buffer.dataBuffer)
        let status = copied.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 3840, destination: $0.baseAddress!)
        }
        XCTAssertEqual(status, noErr)
        XCTAssertEqual(copied, samples)
    }

    func testFormatDescriptionsAreCachedByFormat() throws {
        let cache = FormatDescriptionCache()
        let stereo = try cache.description(for: PCMFormat(sampleRate: 44100, channelCount: 2))
        let again = try cache.description(for: PCMFormat(sampleRate: 44100, channelCount: 2))
        let mono = try cache.description(for: PCMFormat(sampleRate: 44100, channelCount: 1))
        let otherRate = try cache.description(for: PCMFormat(sampleRate: 48000, channelCount: 2))

        XCTAssertTrue(stereo === again)
        XCTAssertFalse(stereo === mono)
        XCTAssertFalse(stereo === otherRate)
        XCTAssertEqual(otherRate.audioStreamBasicDescription?.mSampleRate, 48000)
    }
}
