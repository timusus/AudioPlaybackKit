import Foundation
import PlaybackPlayer
import PlaybackPlayerTestSupport
import PlaybackRender
import PlaybackRenderTestSupport
import XCTest

// Example processors. They are examples to copy, not API: effects belong in the app.
//
// The contract in short: `configure` stages the item's format and returns the output format;
// `flush` applies it and marks a new start (an item, a join, a seek), so clear all running state
// there; `process` runs per chunk on the transport's queue, so state the app also touches needs a lock.

/// Fades in over `frames` after every flush, so a seek or a new item never starts with a click.
/// Keeps every frame where it is, so it is a plain `AudioProcessor` that rewrites the chunk in place.
final class FadeIn: AudioProcessor, @unchecked Sendable {
    private let lock = NSLock()
    private let rampFrames: Int
    private var stagedChannels = 1
    private var channels = 1
    private var framesDone = 0

    init(frames: Int) {
        rampFrames = frames
    }

    var isActive: Bool { true }

    func configure(_ input: PCMFormat) throws -> PCMFormat {
        lock.withLock { stagedChannels = input.channelCount }
        return input
    }

    func process(_ samples: UnsafeMutableBufferPointer<Float>) {
        lock.withLock {
            for frame in 0..<samples.count / channels {
                let gain = min(1, Float(framesDone) / Float(rampFrames))
                framesDone += 1
                for channel in 0..<channels { samples[frame * channels + channel] *= gain }
            }
        }
    }

    func flush(_ metadata: StreamMetadata) {
        lock.withLock { (channels, framesDone) = (stagedChannels, 0) }
    }

    func reset() {
        lock.withLock { (stagedChannels, channels, framesDone) = (1, 1, 0) }
    }
}

/// Reads the audio and changes nothing: the app polls `peak` from its display link.
final class LevelMeter: AudioProcessor, @unchecked Sendable {
    private let lock = NSLock()
    private var _peak: Float = 0
    private var _flushes: [Int64] = []

    var peak: Float { lock.withLock { _peak } }
    /// The media frame each flush started at, to see seeks and joins.
    var flushedAt: [Int64] { lock.withLock { _flushes } }

    var isActive: Bool { true }
    func configure(_ input: PCMFormat) throws -> PCMFormat { input }

    func process(_ samples: UnsafeMutableBufferPointer<Float>) {
        let chunkPeak = samples.reduce(0) { max($0, abs($1)) }
        lock.withLock { _peak = max(_peak, chunkPeak) }
    }

    func flush(_ metadata: StreamMetadata) {
        lock.withLock {
            _peak = 0
            _flushes.append(metadata.mediaStartFrame)
        }
    }

    func reset() {
        lock.withLock { _peak = 0 }
    }
}

/// Stereo (or more) in, mono out. A different channel count means a different output format, so this
/// is a `BufferingAudioProcessor`: input is queued whole and the output taken after it.
final class MonoDownmix: BufferingAudioProcessor, @unchecked Sendable {
    private let lock = NSLock()
    private var stagedChannels = 1
    private var channels = 1
    private var pending: [Float] = []
    private var endQueued = false

    var isActive: Bool { true }

    func configure(_ input: PCMFormat) throws -> PCMFormat {
        lock.withLock { stagedChannels = input.channelCount }
        return PCMFormat(sampleRate: input.sampleRate, channelCount: 1)
    }

    func queueInput(_ samples: [Float]) {
        lock.withLock {
            for frame in 0..<samples.count / channels {
                let slice = samples[frame * channels..<(frame + 1) * channels]
                pending.append(slice.reduce(0, +) / Float(channels))
            }
        }
    }

    func getOutput() -> ProcessorOutput {
        lock.withLock {
            defer { pending = [] }
            return ProcessorOutput(samples: pending)
        }
    }

    func queueEndOfStream() {
        lock.withLock { endQueued = true }
    }

    var isEnded: Bool { lock.withLock { endQueued && pending.isEmpty } }

    func flush(_ metadata: StreamMetadata) {
        lock.withLock { (channels, pending, endQueued) = (stagedChannels, [], false) }
    }

    func reset() {
        lock.withLock { (stagedChannels, channels, pending, endQueued) = (1, 1, [], false) }
    }
}

/// Drops frames quieter than `threshold`. Dropped frames are reported, not forgotten, so the
/// position the player shows stays in the file's own media time.
final class SilenceTrimmer: BufferingAudioProcessor, @unchecked Sendable {
    private let lock = NSLock()
    private let threshold: Float
    private var stagedChannels = 1
    private var channels = 1
    private var pending = ProcessorOutput()
    private var endQueued = false

    init(threshold: Float) {
        self.threshold = threshold
    }

    var isActive: Bool { true }
    func configure(_ input: PCMFormat) throws -> PCMFormat {
        lock.withLock { stagedChannels = input.channelCount }
        return input
    }

    func queueInput(_ samples: [Float]) {
        lock.withLock {
            var run: Int64 = 0
            func closeRun() {
                guard run > 0 else { return }
                pending.dropped.append(DroppedFrames(atOutputFrame: pending.samples.count / channels, inputFrames: run))
                run = 0
            }
            for frame in 0..<samples.count / channels {
                let slice = samples[frame * channels..<(frame + 1) * channels]
                if slice.allSatisfy({ abs($0) < threshold }) {
                    run += 1
                } else {
                    closeRun()
                    pending.samples.append(contentsOf: slice)
                }
            }
            closeRun()
        }
    }

    func getOutput() -> ProcessorOutput {
        lock.withLock {
            defer { pending = ProcessorOutput() }
            return pending
        }
    }

    func queueEndOfStream() {
        lock.withLock { endQueued = true }
    }

    var isEnded: Bool { lock.withLock { endQueued && pending.samples.isEmpty && pending.dropped.isEmpty } }

    func flush(_ metadata: StreamMetadata) {
        lock.withLock { (channels, pending, endQueued) = (stagedChannels, ProcessorOutput(), false) }
    }

    func reset() {
        lock.withLock { (stagedChannels, channels, pending, endQueued) = (1, 1, ProcessorOutput(), false) }
    }
}

// MARK: - Driving a processor by hand, to see frames in and out

final class AudioProcessorRecipe: XCTestCase {
    private let mono = PCMFormat(sampleRate: 8, channelCount: 1)
    private let stereo = PCMFormat(sampleRate: 8, channelCount: 2)
    private let start = StreamMetadata(item: Track(id: 1), mediaStartFrame: 0)

    func testAnInPlaceProcessorRewritesTheChunkAndRestartsAfterASeek() throws {
        let fade = FadeIn(frames: 4)
        XCTAssertEqual(try fade.configure(mono), mono) // in place: the format is the input's
        fade.flush(start) // `configure` only staged; `flush` applies

        var chunk: [Float] = [1, 1, 1, 1, 1, 1]
        chunk.withUnsafeMutableBufferPointer { fade.process($0) }
        XCTAssertEqual(chunk, [0, 0.25, 0.5, 0.75, 1, 1])

        // A seek flushes every stage with the landed frame; the fade starts over.
        fade.flush(StreamMetadata(item: Track(id: 1), mediaStartFrame: 40))
        var again: [Float] = [1, 1]
        again.withUnsafeMutableBufferPointer { fade.process($0) }
        XCTAssertEqual(again, [0, 0.25])
    }

    func testAChannelCountChangeIsABufferingProcessor() throws {
        let downmix = MonoDownmix()
        XCTAssertEqual(try downmix.configure(stereo), mono)
        downmix.flush(start)

        downmix.queueInput([1, 3, 2, 4]) // two stereo frames in
        XCTAssertEqual(downmix.getOutput().samples, [2, 3]) // two mono frames out
        downmix.queueEndOfStream()
        XCTAssertTrue(downmix.isEnded)
    }

    func testDroppedFramesAreReportedAtTheirOutputPosition() throws {
        let trimmer = SilenceTrimmer(threshold: 0.01)
        _ = try trimmer.configure(mono)
        trimmer.flush(start)

        trimmer.queueInput([0, 0, 0.5, 0.6, 0, 0.7, 0, 0])
        let output = trimmer.getOutput()

        XCTAssertEqual(output.samples, [0.5, 0.6, 0.7])
        // Output plus dropped equals input: 3 + 5 = 8 frames.
        XCTAssertEqual(output.dropped, [
            DroppedFrames(atOutputFrame: 0, inputFrames: 2),
            DroppedFrames(atOutputFrame: 2, inputFrames: 1),
            DroppedFrames(atOutputFrame: 3, inputFrames: 2),
        ])
    }
}

// MARK: - On a player

@MainActor
final class AudioProcessorOnPlayerRecipe: XCTestCase {
    func testProcessorsRunInOrderAndSeeEverySeek() {
        let factory = FakeItemFactory<Track>(format: PCMFormat(sampleRate: 8, channelCount: 2))
        let rig = PlayerTestRig<Track> { try factory.make($0) }
        let meter = LevelMeter()
        rig.player.setProcessors([meter, MonoDownmix()]) // the meter hears stereo; the speaker gets mono
        rig.player.setItems([Track(id: 1)])
        rig.player.play()
        rig.run(for: 3)

        XCTAssertGreaterThan(meter.peak, 0)
        XCTAssertEqual(Set(rig.output.enqueues.map(\.format.channelCount)), [1])

        rig.player.seek(to: 5)
        rig.run(for: 1)

        // Frame 0 at the start, then the landed frame of the seek: 5 s at 8 Hz.
        XCTAssertEqual(meter.flushedAt, [0, 40])
    }
}
