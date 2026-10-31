@testable @_spi(Testing) import PlaybackRender
@_spi(Testing) import PlaybackRenderTestSupport
import XCTest

/// The position cases of media3 `DefaultAudioSinkTest`, adapted: dropped frames count when they would
/// have played, and speed is the output's rate. Then the edge cases of the #93 plan, driven through
/// the fake output.
final class MediaPositionMapTests: XCTestCase {
    private let mono = PCMFormat(sampleRate: 44100, channelCount: 1)

    /// Output time of `frames` at 44.1 kHz.
    private func at(_ frames: Int64) -> TimeInterval { Double(frames) / 44100 }

    private func tag(_ item: Int, _ mediaStartFrame: Int64, _ frameCount: Int64) -> SegmentTag {
        SegmentTag(item: item, mediaStartFrame: mediaStartFrame, frameCount: frameCount)
    }

    private func entered(_ items: Int...) -> [MediaPositionMap.Heard] {
        items.map { .item($0, mono) }
    }

    private func ramp(from: Int64, count: Int64) -> [Float] {
        (from..<(from + count)).map(Float.init)
    }

    // MARK: Ported from the spike

    func testPositionStartsAtTheFirstTagsMediaFrame() {
        var map = MediaPositionMap()
        map.append(tag(0, 220500, 44100), format: mono)
        XCTAssertEqual(map.position(at: 0), .init(item: 0, mediaFrame: 220500, sampleRate: 44100))

        map.reset(at: 3)
        map.append(tag(0, 352800, 44100), format: mono)
        XCTAssertEqual(map.position(at: 3), .init(item: 0, mediaFrame: 352800, sampleRate: 44100))
    }

    func testNothingWrittenHasNoPosition() {
        XCTAssertNil(MediaPositionMap().position(at: 0))
    }

    // media3 credits the 441 dropped frames as soon as they are processed.
    func testDroppedFramesCountOnlyOnceThePlayheadReachesThem() {
        var map = MediaPositionMap()
        map.append(tag(0, 0, 22050), format: mono)
        map.append(tag(0, 22491, 22050), format: mono)

        XCTAssertEqual(map.position(at: at(11025))?.mediaFrame, 11025, "no early jump while the drop is queued")
        XCTAssertEqual(map.position(at: at(22049))?.mediaFrame, 22049)
        XCTAssertEqual(map.position(at: at(22050))?.mediaFrame, 22491)
        XCTAssertEqual(map.position(at: at(44100))?.mediaFrame, 44541)
    }

    func testPlayheadBeyondWhatWasWrittenHoldsAtTheEnd() {
        var map = MediaPositionMap()
        map.append(tag(0, 0, 1000), format: mono)
        XCTAssertEqual(map.position(at: at(5000))?.mediaFrame, 1000, "a starved output must not run the position on")
    }

    func testAGaplessBoundaryIsReportedWhenThePlayheadCrossesIt() {
        var map = MediaPositionMap()
        map.append(tag(0, 0, 44100), format: mono)
        map.append(tag(1, 0, 44100), format: mono)

        XCTAssertEqual(map.advance(to: 0), entered(0))
        XCTAssertEqual(map.advance(to: at(44099)), [], "written is not played")
        XCTAssertEqual(map.position(at: at(44099)), .init(item: 0, mediaFrame: 44099, sampleRate: 44100))
        XCTAssertEqual(map.advance(to: at(44100)), entered(1))
        XCTAssertEqual(map.advance(to: at(50000)), [])
        XCTAssertEqual(map.position(at: at(50000)), .init(item: 1, mediaFrame: 5900, sampleRate: 44100))
    }

    func testAZeroFrameItemStillEnds() {
        var map = MediaPositionMap()
        map.append(tag(0, 0, 100), format: mono)
        map.append(tag(1, 0, 0), format: mono)
        map.append(tag(2, 0, 100), format: mono)
        map.append(tag(3, 0, 0), format: mono)

        XCTAssertEqual(map.advance(to: at(50)), entered(0))
        XCTAssertEqual(map.advance(to: at(150)), entered(1, 2), "item 1 is entered and left in one step")
        XCTAssertEqual(map.advance(to: at(200)), entered(3), "a zero-frame last item is still reached")
        XCTAssertEqual(map.position(at: at(200)), .init(item: 3, mediaFrame: 0, sampleRate: 44100))
    }

    func testAdvancingKeepsLaterPositionsExact() {
        var map = MediaPositionMap()
        map.append(tag(0, 0, 1000), format: mono)
        map.append(tag(0, 1500, 1000), format: mono)
        _ = map.advance(to: at(1500))
        XCTAssertEqual(map.position(at: at(1500))?.mediaFrame, 2000)
        XCTAssertEqual(map.position(at: at(2000))?.mediaFrame, 2500)
    }

    // MARK: The #93 edge cases

    func testATimestampJumpOver200msMovesThePositionOnlyWhenPlayed() {
        var map = MediaPositionMap()
        map.append(tag(0, 0, 44100), format: mono)
        map.append(tag(0, 57330, 44100), format: mono)

        XCTAssertEqual(map.writtenEnd, 2, "the output stays contiguous across the 300 ms jump")
        XCTAssertEqual(map.advance(to: at(22050)), entered(0))
        XCTAssertEqual(map.position(at: at(22050))?.mediaFrame, 22050)
        XCTAssertEqual(map.advance(to: at(44100)), [], "a jump is not an item boundary")
        XCTAssertEqual(map.position(at: at(44100))?.mediaFrame, 57330)
        XCTAssertEqual(map.position(at: at(66150))?.mediaFrame, 79380)
    }

    func testAFormatChangeAtAJoinMapsEachItemAtItsOwnRate() throws {
        let output = FakeAudioOutput()
        let stereo48 = PCMFormat(sampleRate: 48000, channelCount: 2)
        var map = MediaPositionMap()
        map.append(tag(0, 0, 44100), format: mono)
        try output.enqueue(ramp(from: 0, count: 44100), format: mono, at: 0)
        let join = map.writtenEnd
        map.append(tag(1, 0, 48000), format: stereo48)
        try output.enqueue([Float](repeating: 1, count: 96000), format: stereo48, at: join)

        output.setRate(1, at: 0)
        output.advance(by: 0.5)
        XCTAssertEqual(map.advance(to: output.currentTime()), entered(0))
        XCTAssertEqual(map.position(at: output.currentTime()), .init(item: 0, mediaFrame: 22050, sampleRate: 44100))
        output.advance(by: 0.5)
        XCTAssertEqual(map.advance(to: output.currentTime()), [.item(1, stereo48)])
        XCTAssertEqual(map.position(at: output.currentTime()), .init(item: 1, mediaFrame: 0, sampleRate: 48000))
        output.advance(by: 0.5)
        XCTAssertEqual(map.position(at: output.currentTime()), .init(item: 1, mediaFrame: 24000, sampleRate: 48000))

        XCTAssertEqual(join, 1)
        XCTAssertEqual(output.played.count, 2, "the join has no silence")
        XCTAssertEqual(output.played.last, .audio(start: 1, format: stereo48, samples: [Float](repeating: 1, count: 48000)))
    }

    // #181: a format change within an item is reported when heard, and only a channel count may move.
    func testAFormatChangeWithinAnItemIsEnteredWhenTheChangeIsHeard() {
        let stereo = PCMFormat(sampleRate: 44100, channelCount: 2)
        var map = MediaPositionMap()
        map.append(tag(0, 0, 44100), format: mono)
        map.append(tag(0, 44100, 44100), format: stereo)

        XCTAssertEqual(map.advance(to: 0), entered(0))
        XCTAssertEqual(map.advance(to: at(44099)), [], "written is not heard")
        XCTAssertEqual(map.advance(to: at(44100)), [.format(item: 0, stereo)])
        XCTAssertEqual(map.advance(to: at(88200)), [])
    }

    func testAReAnchorInsideAnItemReportsOnlyAFormatItChanges() {
        let stereo = PCMFormat(sampleRate: 44100, channelCount: 2)
        var map = MediaPositionMap()
        map.append(tag(0, 0, 44100), format: mono)
        XCTAssertEqual(map.advance(to: 0), entered(0))

        map.reset(at: 1)
        map.append(tag(0, 0, 44100), format: mono)
        XCTAssertEqual(map.advance(to: 1), [])

        map.reset(at: 2)
        map.append(tag(0, 88200, 44100), format: stereo)
        XCTAssertEqual(map.advance(to: 2), [.format(item: 0, stereo)])
    }

    // Speed is the output rate, so the map has no speed checkpoint for the position to jump at.
    func testARateChangeLeavesTheMediaPositionContinuous() throws {
        let output = FakeAudioOutput()
        var map = MediaPositionMap()
        map.append(tag(0, 0, 176400), format: mono)
        try output.enqueue(ramp(from: 0, count: 176400), format: mono, at: 0)
        output.setRate(1, at: 0)
        output.advance(by: 1)
        XCTAssertEqual(map.position(at: output.currentTime())?.mediaFrame, 44100)

        output.setRate(2, at: nil)
        XCTAssertEqual(map.position(at: output.currentTime())?.mediaFrame, 44100)
        output.advance(by: 0.5)
        XCTAssertEqual(map.position(at: output.currentTime())?.mediaFrame, 88200)
        output.setRate(1, at: nil)
        output.advance(by: 0.5)
        XCTAssertEqual(map.position(at: output.currentTime())?.mediaFrame, 110250)
    }

    func testASeekWhilePausedLeavesNoStalePosition() throws {
        let output = FakeAudioOutput()
        output.outputLatency = 0.25
        var map = MediaPositionMap()
        var heard: TimeInterval { map.playhead(currentTime: output.currentTime(), outputLatency: output.outputLatency) }
        map.append(tag(0, 0, 88200), format: mono)
        try output.enqueue([Float](repeating: 1, count: 88200), format: mono, at: 0)
        output.setRate(1, at: 0)
        output.advance(by: 0.5)
        output.setRate(0, at: nil)
        XCTAssertEqual(map.advance(to: heard), entered(0))
        XCTAssertEqual(map.position(at: heard)?.mediaFrame, 11025, "a quarter second is still in the hardware")

        output.flush()
        output.setRate(0, at: 10)
        map.reset(at: 10)
        XCTAssertNil(map.position(at: heard), "nothing of the new epoch is written yet")
        map.append(tag(0, 441000, 44100), format: mono)
        try output.enqueue([Float](repeating: 2, count: 44100), format: mono, at: 10)
        XCTAssertEqual(heard, 10, "the clock reads the anchor; the latency must not reach back into the old epoch")
        XCTAssertEqual(map.position(at: heard), .init(item: 0, mediaFrame: 441000, sampleRate: 44100))

        output.setRate(1, at: nil)
        output.advance(by: 0.5)
        XCTAssertEqual(map.advance(to: heard), [], "a seek inside the item crosses no boundary")
        XCTAssertEqual(map.position(at: heard)?.mediaFrame, 452025)
        XCTAssertEqual(output.played, [
            .audio(start: 0, format: mono, samples: [Float](repeating: 1, count: 22050)),
            .audio(start: 10, format: mono, samples: [Float](repeating: 2, count: 22050)),
        ])
    }

    func testAnAutoFlushReAnchorsAtTheFlushTime() throws {
        let output = FakeAudioOutput()
        var map = MediaPositionMap()
        map.append(tag(0, 0, 88200), format: mono)
        try output.enqueue(ramp(from: 0, count: 88200), format: mono, at: 0)
        output.setRate(1, at: 0)
        output.advance(by: 0.5)
        XCTAssertEqual(map.advance(to: output.currentTime()), entered(0))
        output.injectAutoFlush()
        output.advance(by: 0.25)

        guard case let .autoFlushed(flushTime)? = output.events.last else { return XCTFail("no auto-flush") }
        let resume = try XCTUnwrap(map.position(at: flushTime))
        XCTAssertEqual(resume, .init(item: 0, mediaFrame: 22050, sampleRate: 44100))
        map.reset(at: flushTime)
        map.append(tag(0, resume.mediaFrame, 66150), format: mono)
        try output.enqueue(ramp(from: resume.mediaFrame, count: 66150), format: mono, at: flushTime)

        XCTAssertEqual(map.position(at: output.currentTime())?.mediaFrame, 33075, "the clock ran on while the event was handled")
        output.advance(by: 0.25)
        XCTAssertEqual(map.advance(to: output.currentTime()), [])
        XCTAssertEqual(map.position(at: output.currentTime())?.mediaFrame, 44100)
        XCTAssertEqual(output.played, [
            .audio(start: 0, format: mono, samples: ramp(from: 0, count: 22050)),
            .silence(start: 0.5, duration: 0.25),
            .audio(start: 0.75, format: mono, samples: ramp(from: 33075, count: 11025)),
        ], "the re-fed audio is heard at the media frame the map reports")
    }

    func testThePlayheadIsTheClockLessLatencyAndNeverBeforeTheEpoch() {
        let map = MediaPositionMap(epochStart: 10)
        XCTAssertEqual(map.playhead(currentTime: 10.5, outputLatency: 0.25), 10.25)
        XCTAssertEqual(map.playhead(currentTime: 10.5, outputLatency: 0), 10.5, "a clock that includes latency reports 0")
        XCTAssertEqual(map.playhead(currentTime: 10.125, outputLatency: 0.25), 10)
    }

    // MARK: Stretched segments

    func testAStretchedSegmentLastsItsOutputFramesAndMapsAtItsRatio() {
        var map = MediaPositionMap()
        map.append(tag(0, 0, 44100), format: mono, outputFrames: 29400)

        XCTAssertEqual(map.writtenEnd, at(29400))
        XCTAssertEqual(map.position(at: at(14700))?.mediaFrame, 22050)
        XCTAssertEqual(map.position(at: at(29400))?.mediaFrame, 44100)
    }

    func testARatioChangeStartsASegmentAndTheSameRatioMerges() {
        var map = MediaPositionMap()
        map.append(tag(0, 0, 44100), format: mono)
        map.append(tag(0, 44100, 44100), format: mono, outputFrames: 29400)
        map.append(tag(0, 88200, 44100), format: mono, outputFrames: 29400)
        _ = map.advance(to: at(44100))

        XCTAssertEqual(map.position(at: at(44100 + 14700))?.mediaFrame, 66150)
        XCTAssertEqual(map.position(at: at(44100 + 44100))?.mediaFrame, 110250)
        XCTAssertEqual(map.writtenEnd, at(44100 + 58800), accuracy: 1e-9)
    }

    func testAStretchedSegmentWithNoOutputYetAddsNoTime() {
        var map = MediaPositionMap()
        map.append(tag(0, 0, 44100), format: mono)
        map.append(tag(1, 0, 300), format: mono, outputFrames: 0)
        map.append(tag(1, 300, 44100), format: mono, outputFrames: 22050)

        XCTAssertEqual(map.writtenEnd, at(66150))
        XCTAssertEqual(map.advance(to: at(44100)), entered(0, 1))
        XCTAssertEqual(map.position(at: at(44100 + 11025))?.mediaFrame, 22350)
    }

    func testTruncatingAStretchedSegmentKeepsWholeOutputFramesAndResumesAtTheirMediaFrame() throws {
        var map = MediaPositionMap()
        map.append(tag(0, 0, 88200), format: mono, outputFrames: 58800)

        let cut = try XCTUnwrap(map.truncate(from: at(29400)))
        XCTAssertEqual(cut.time, at(29400))
        XCTAssertEqual(cut.resume, .init(item: 0, mediaFrame: 44100, sampleRate: 44100))
        XCTAssertEqual(map.writtenEnd, at(29400))
        XCTAssertEqual(map.position(at: at(29400))?.mediaFrame, 44100)
    }
}
