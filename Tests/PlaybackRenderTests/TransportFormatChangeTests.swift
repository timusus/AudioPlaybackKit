import Foundation
@testable @_spi(Testing) import PlaybackRender
import PlaybackRenderTestSupport
import XCTest

/// A three-second item a server re-encodes: it opens in `formats[0]` and moves to the next format at
/// each of `switchFrames` (counted in the format then playing), or on the first seek, which re-opens
/// the stream at that time as Shuttle2's `TimeOffsetItemSource` does. By default it opens at 8 Hz mono
/// and changes to 16 Hz stereo. Samples count from 1000 × the format's index.
private final class ReencodedSource: ItemSource, @unchecked Sendable {
    static let before = PCMFormat(sampleRate: 8, channelCount: 1)
    static let after = PCMFormat(sampleRate: 16, channelCount: 2)

    private let formats: [PCMFormat]
    private var switchFrames: [Int64]
    private let chunkFrames: Int64
    private var index = 0
    private var position: Int64 = 0
    private(set) var seeks: [Int64] = []

    init(switchFrames: [Int64], formats: [PCMFormat] = [before, after], chunkFrames: Int64 = 2) {
        self.switchFrames = switchFrames
        self.formats = formats
        self.chunkFrames = chunkFrames
    }

    var currentFormat: PCMFormat? { index == 0 ? nil : format }
    var frameCount: Int64? { Int64(3 * format.sampleRate) }
    private var format: PCMFormat { formats[index] }

    func begin(epoch: UInt64) {}
    func open() throws -> PCMFormat { formats[0] }

    func seek(toFrame frame: Int64) throws -> Int64 {
        seeks.append(frame)
        let seconds = Double(frame) / format.sampleRate
        index = max(index, 1)
        position = Int64((seconds * format.sampleRate).rounded())
        return position
    }

    /// Changes format between the sequencer's calls, which the protocol does not allow.
    func switchNow() {
        switchFormat()
    }

    func nextChunk() throws -> [Float]? {
        if position == switchFrames.first {
            switchFrames.removeFirst()
            switchFormat()
        }
        guard position < frameCount! else { return nil }
        let channels = Int64(format.channelCount)
        let end = min(position + chunkFrames, frameCount!)
        defer { position = end }
        let base = Float(1000 * index)
        return (position * channels..<end * channels).map { base + Float($0) }
    }

    private func switchFormat() {
        let old = format.sampleRate
        index += 1
        position = Int64((Double(position) * format.sampleRate / old).rounded())
    }

    func interrupt(through epoch: UInt64) {}
    func release() {}
}

/// A source changing format mid-item plays on through one drain and reconfiguration, as media3
/// `DefaultAudioSink.configure` does on `onOutputFormatChanged` within one period.
final class TransportFormatChangeTests: XCTestCase {
    private let output = FakeAudioOutput()
    private let timer = ManualPumpTimer()
    private let executor = ManualExecutor()
    private let recorder = EventRecorder()
    private let processor = RecordingProcessor()
    private lazy var transport = Transport<String>(output: output, timer: timer, executor: executor) { [recorder] in
        recorder.append($0)
    }

    /// `transport.position` after each pump, as a UI polling it reads.
    private var itemPositions: [(item: String, seconds: TimeInterval)] = []

    private func pump() {
        timer.sync()
        executor.runUntilIdle()
        timer.fire()
        if let position = transport.position { itemPositions.append((position.item, position.seconds)) }
    }

    private func run(for seconds: TimeInterval) {
        for _ in 0..<Int(seconds * 8) {
            output.advance(by: 0.125)
            pump()
        }
    }

    private func start(_ source: ReencodedSource) {
        transport.setProcessors([processor])
        transport.setCurrent(item: "a", source: source)
        transport.play()
        pump()
    }

    private var failures: Int {
        recorder.events.filter { if case .failed = $0 { true } else { false } }.count
    }

    private var positions: [TimeInterval] { itemPositions.map(\.seconds) }

    private var durations: [TimeInterval?] {
        recorder.events.compactMap { if case let .durationChanged(_, duration, _) = $0 { Optional(duration) } else { nil } }
    }

    /// The formats reported as heard, in order: `.crossed` and `.formatChanged`.
    private var heardFormats: [String] {
        recorder.events.compactMap {
            switch $0 {
            case let .crossed(item, format): "crossed \(item) \(format.sampleRate)x\(format.channelCount)"
            case let .formatChanged(item, format): "changed \(item) \(format.sampleRate)x\(format.channelCount)"
            default: nil
            }
        }
    }

    private var ended: Bool {
        recorder.events.contains { if case .status(.ended) = $0 { true } else { false } }
    }

    private func firstSample(after enqueues: Int) -> Float? {
        output.enqueues.dropFirst(enqueues).first?.samples.first
    }

    private func flush(_ frame: Int64) -> RecordingProcessor.Event {
        .flush(StreamMetadata(item: "a", mediaStartFrame: frame))
    }

    func testAMidItemFormatChangeDrainsReconfiguresAndPlaysOnInTheNewFormat() {
        start(ReencodedSource(switchFrames: [8]))
        run(for: 4)

        XCTAssertEqual(failures, 0)
        XCTAssertEqual(processor.configured, [ReencodedSource.before, ReencodedSource.after])
        XCTAssertEqual(
            processor.events,
            [flush(0)] + Array(repeating: .input(frames: 2), count: 4) + [flush(16)] + Array(repeating: .input(frames: 2), count: 16)
        )
        XCTAssertEqual(output.enqueues.map(\.format), Array(repeating: ReencodedSource.before, count: 4) + Array(repeating: ReencodedSource.after, count: 16))
        XCTAssertEqual(output.enqueues[4].samples, [1032, 1033, 1034, 1035])
        XCTAssertEqual(output.enqueues[4].time, 1, "the new format follows the old with no gap")
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertTrue(positions.contains(1))
        XCTAssertEqual(positions.last, 3)
        XCTAssertTrue(ended)
    }

    // #181: b's change 1 s in is decoded about two seconds ahead of the playhead, so before b is heard.
    func testTheCrossingCarriesTheStartingFormatAndTheChangeIsReportedWhenHeard() {
        start(ReencodedSource(switchFrames: []))
        transport.setNext(item: "b", source: ReencodedSource(switchFrames: [8]))
        pump()
        run(for: 2.875)
        XCTAssertTrue(output.enqueues.contains { $0.format == ReencodedSource.after }, "b's change is decoded ahead")
        XCTAssertEqual(heardFormats, ["crossed a 8.0x1"])

        run(for: 0.125)
        XCTAssertEqual(heardFormats, ["crossed a 8.0x1", "crossed b 8.0x1"], "b starts in its first format")

        run(for: 0.875)
        XCTAssertEqual(heardFormats.count, 2, "the change is not heard yet")

        run(for: 0.125)
        XCTAssertEqual(itemPositions.last?.item, "b")
        XCTAssertEqual(itemPositions.last?.seconds, 1)
        XCTAssertEqual(heardFormats, ["crossed a 8.0x1", "crossed b 8.0x1", "changed b 16.0x2"])

        run(for: 3)
        XCTAssertEqual(heardFormats.count, 3, "reported once")
        XCTAssertTrue(ended)
    }

    func testASeekThatReopensInAnotherFormatReportsItOnceItsAudioIsHeard() {
        start(ReencodedSource(switchFrames: []))
        run(for: 0.5)

        transport.seek(item: "a", toSeconds: 2)
        pump()
        run(for: 2)

        XCTAssertEqual(heardFormats, ["crossed a 8.0x1", "changed a 16.0x2"])
    }

    func testASeekThatReopensInAnotherFormatPlaysOnFromTheTarget() {
        start(ReencodedSource(switchFrames: []))
        run(for: 0.5)
        let enqueues = output.enqueues.count
        let events = processor.events.count
        let sought = positions.count

        transport.seek(item: "a", toSeconds: 2)
        pump()
        run(for: 2)

        XCTAssertEqual(failures, 0)
        XCTAssertEqual(processor.configured.last, ReencodedSource.after)
        XCTAssertEqual(Array(processor.events.dropFirst(events).prefix(2)), [flush(32), .input(frames: 2)])
        XCTAssertEqual(firstSample(after: enqueues), 1064)
        XCTAssertEqual(positions.dropFirst(sought).first, 2)
        XCTAssertEqual(positions.last, 3)
        XCTAssertTrue(ended)
    }

    func testAnAutoFlushHeardBeforeTheChangeRefeedsFromTheSameTime() {
        start(ReencodedSource(switchFrames: [8]))
        run(for: 0.75)
        let enqueues = output.enqueues.count
        let before = positions.last

        output.injectAutoFlush()
        pump()
        run(for: 3)

        XCTAssertEqual(before, 0.75)
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(firstSample(after: enqueues), 1024, "0.75 s re-opened at 16 Hz is frame 12")
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertEqual(positions.last, 3)
    }

    func testAChangeSeenBeforeAChunkWithNoSeekStillKeepsTimeContinuous() {
        let source = ReencodedSource(switchFrames: [])
        start(source)
        source.switchNow()
        run(for: 4)

        XCTAssertEqual(failures, 0)
        XCTAssertEqual(processor.configured, [ReencodedSource.before, ReencodedSource.after])
        XCTAssertEqual(processor.events.filter { if case .flush = $0 { true } else { false } }, [flush(0), flush(16)])
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertEqual(positions.last, 3)
        XCTAssertTrue(ended)
    }

    func testAChangeInTheLastChunkJoinsTheNextItemFromItsStartWithNoGap() {
        // Down from 16 Hz stereo to 8 Hz mono at frame 44, so the last chunk alone is in the new format.
        let formats = [ReencodedSource.after, ReencodedSource.before]
        start(ReencodedSource(switchFrames: [44], formats: formats))
        transport.setNext(item: "b", source: ReencodedSource(switchFrames: [], formats: formats))
        pump()
        run(for: 7)

        XCTAssertEqual(failures, 0)
        XCTAssertEqual(processor.configured, [ReencodedSource.after, ReencodedSource.before, ReencodedSource.after])
        XCTAssertEqual(processor.events.filter { if case .flush = $0 { true } else { false } },
                       [flush(0), flush(22), .flush(StreamMetadata(item: "b", mediaStartFrame: 0))])
        let aLast = output.enqueues.suffix(25).first, bFirst = output.enqueues.suffix(24).first
        XCTAssertEqual(aLast?.samples, [1022, 1023])
        XCTAssertEqual(aLast?.format, ReencodedSource.before)
        XCTAssertEqual(aLast?.time, 2.75)
        XCTAssertEqual(bFirst?.samples, [0, 1, 2, 3])
        XCTAssertEqual(bFirst?.format, ReencodedSource.after)
        XCTAssertEqual(bFirst?.time, 3, "b starts at its first frame straight after a's last, in its own format")
        XCTAssertEqual(itemPositions.filter { $0.item == "b" }.first?.seconds, 0)
        XCTAssertEqual(itemPositions.filter { $0.item == "b" }.last?.seconds, 3)
        XCTAssertTrue(ended)
    }

    func testASeekBackReplaysTheJoinIntoANextItemAlreadyOpened() {
        start(ReencodedSource(switchFrames: [22]))
        let next = ReencodedSource(switchFrames: [])
        transport.setNext(item: "b", source: next)
        pump()
        run(for: 2.5)
        let configured = processor.configured.count
        let events = processor.events.count
        let enqueues = output.enqueues.count

        transport.seek(item: "a", toSeconds: 2.75)
        pump()
        run(for: 4)

        XCTAssertEqual(failures, 0)
        XCTAssertEqual(next.seeks, [0], "the join rewinds a next item opened before the seek")
        XCTAssertEqual(processor.events.dropFirst(events).filter { if case .flush = $0 { true } else { false } },
                       [flush(44), .flush(StreamMetadata(item: "b", mediaStartFrame: 0))])
        XCTAssertEqual(firstSample(after: enqueues), 1088)
        // This source re-opens at 16 Hz stereo on any seek, so the rewound b adopts that from frame 0.
        XCTAssertEqual(processor.configured.dropFirst(configured), [ReencodedSource.after, ReencodedSource.after])
        XCTAssertEqual(itemPositions.filter { $0.item == "b" }.last?.seconds, 3)
        XCTAssertTrue(ended)
    }

    func testThePositionsDurationStaysInSecondsAcrossTheChange() {
        start(ReencodedSource(switchFrames: [8]))
        run(for: 4)

        XCTAssertEqual(Set(durations), [3])
    }

    func testAChangeAfterASeekThatChangedFormatRescalesFromTheLandedFrame() {
        let third = PCMFormat(sampleRate: 32, channelCount: 2)
        start(ReencodedSource(switchFrames: [40], formats: [ReencodedSource.before, ReencodedSource.after, third]))
        run(for: 0.5)
        let events = processor.events.count

        transport.seek(item: "a", toSeconds: 2)
        pump()
        run(for: 2)

        XCTAssertEqual(failures, 0)
        XCTAssertEqual(processor.configured.suffix(2), [ReencodedSource.after, third])
        XCTAssertEqual(processor.events.dropFirst(events).filter { if case .flush = $0 { true } else { false } }, [flush(32), flush(80)])
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertEqual(itemPositions.last?.seconds, 3)
        XCTAssertEqual(Set(durations), [3])
        XCTAssertTrue(ended)
    }

    func testA44100To48000ChangeRoundsToTheNearestFrame() {
        let cd = PCMFormat(sampleRate: 44100, channelCount: 1)
        let dat = PCMFormat(sampleRate: 48000, channelCount: 1)
        start(ReencodedSource(switchFrames: [12000], formats: [cd, dat], chunkFrames: 3000))
        run(for: 0.25)
        let enqueues = output.enqueues.count
        let before = itemPositions.last

        output.injectAutoFlush()
        pump()
        run(for: 4)

        XCTAssertEqual(failures, 0)
        XCTAssertTrue(processor.events.contains(flush(13061)), "12000 at 44.1 kHz is 13061.22 at 48 kHz")
        XCTAssertEqual(before?.seconds, 5513.0 / 44100)
        XCTAssertEqual(firstSample(after: enqueues), 1000 + 6001, "frame 5513 at 44.1 kHz is 6000.54 at 48 kHz")
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertEqual(positions.last, 3)
        XCTAssertEqual(Set(durations), [3])
    }
}
