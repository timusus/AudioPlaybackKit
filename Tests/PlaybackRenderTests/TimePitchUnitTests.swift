import AudioToolbox
import AVFoundation
@testable import PlaybackRender
import XCTest

final class TimePitchUnitTests: XCTestCase {
    static func fixture(seconds: Int) -> [Float] {
        var state: UInt32 = 12345
        return (0..<(48000 * seconds)).flatMap { frame -> [Float] in
            state = state &* 1664525 &+ 1013904223
            let noise = Float(state >> 16) / 65536 - 0.5
            let time = Float(frame) / 48000
            return [0.4 * sinf(2 * .pi * 440 * time) + 0.05 * noise, 0.3 * sinf(2 * .pi * 660 * time) - 0.05 * noise]
        }
    }

    /// Feeds `chunk`-frame chunks and renders what each leaves, as `TimeStretch` does.
    static func stretch(_ samples: [Float], rate: Double, chunk: Int, through unit: some StretchUnit) -> [Float] {
        unit.rate = rate
        var output: [Float] = []
        for start in stride(from: 0, to: samples.count, by: chunk * 2) {
            unit.append(Array(samples[start..<min(start + chunk * 2, samples.count)]))
            output += unit.render(Int((Double(unit.queuedFrames) - 1) / rate))
        }
        return output
    }

    // AUNewTimePitch's output differs between OS releases, so the copy path is checked against a
    // plain per-sample reference around the same unit in this process rather than a pinned hash.
    func testStretchedOutputMatchesAPerSampleReference() {
        let samples = Self.fixture(seconds: 5)
        let format = PCMFormat(sampleRate: 48000, channelCount: 2)
        // 4800-frame chunks render below one slice; 24000 at 0.5x renders several 8192-frame slices per call.
        for (rate, chunk) in [(1.5, 4800), (0.5, 24000), (2.0, 1001)] {
            let output = Self.stretch(samples, rate: rate, chunk: chunk, through: TimePitchUnit(format: format))
            let expected = Self.stretch(samples, rate: rate, chunk: chunk, through: ReferenceTimePitch(format: format))
            XCTAssertGreaterThan(output.count, 0)
            XCTAssertEqual(output.count, expected.count, "rate \(rate)")
            XCTAssert(output.map(\.bitPattern) == expected.map(\.bitPattern), "rate \(rate) differs from the reference")
        }
    }
}

/// The same AUNewTimePitch setup as `TimePitchUnit`, copying one sample at a time through an array queue.
private final class ReferenceTimePitch: StretchUnit {
    let window = 2048
    var rate: Double = 1 {
        didSet { AudioUnitSetParameter(unit, kNewTimePitchParam_Rate, kAudioUnitScope_Global, 0, AudioUnitParameterValue(rate), 0) }
    }

    private let channels: Int
    private let unit: AudioUnit
    private var input: [Float] = []
    private var sampleTime = 0.0
    private static let maximumFrames = 8192

    init(format: PCMFormat) {
        channels = format.channelCount
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_FormatConverter, componentSubType: kAudioUnitSubType_NewTimePitch,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
        )
        var instance: AudioUnit?
        AudioComponentInstanceNew(AudioComponentFindNext(nil, &description)!, &instance)
        unit = instance!
        var stream = AudioStreamBasicDescription(
            mSampleRate: format.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0
        )
        let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &stream, size)
        AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &stream, size)
        var maximum = UInt32(Self.maximumFrames)
        AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximum, 4)
        var callback = AURenderCallbackStruct(inputProc: { refCon, _, _, _, frames, data in
            Unmanaged<ReferenceTimePitch>.fromOpaque(refCon).takeUnretainedValue().pull(Int(frames), into: data!)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                             &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        AudioUnitInitialize(unit)
    }

    deinit {
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    var queuedFrames: Int { input.count / channels }

    func append(_ samples: [Float]) { input += samples }

    func render(_ frames: Int) -> [Float] {
        var samples: [Float] = []
        var left = frames
        while left > 0 {
            let count = min(left, Self.maximumFrames)
            samples += renderSlice(count)
            left -= count
        }
        return samples
    }

    private func renderSlice(_ frames: Int) -> [Float] {
        let output = AudioBufferList.allocate(maximumBuffers: channels)
        defer {
            for buffer in output { buffer.mData?.deallocate() }
            output.unsafeMutablePointer.deallocate()
        }
        for channel in 0..<channels {
            output[channel] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4),
                                          mData: UnsafeMutableRawPointer.allocate(byteCount: frames * 4, alignment: 16))
        }
        var flags = AudioUnitRenderActionFlags()
        var time = AudioTimeStamp()
        time.mSampleTime = sampleTime
        time.mFlags = .sampleTimeValid
        sampleTime += Double(frames)
        AudioUnitRender(unit, &flags, &time, 0, UInt32(frames), output.unsafeMutablePointer)
        var samples = [Float](repeating: 0, count: frames * channels)
        for channel in 0..<channels {
            let source = output[channel].mData!.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames { samples[frame * channels + channel] = source[frame] }
        }
        return samples
    }

    private func pull(_ frames: Int, into data: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(data)
        let available = min(frames, queuedFrames)
        for channel in 0..<channels {
            let target = buffers[channel].mData!.assumingMemoryBound(to: Float.self)
            for frame in 0..<available { target[frame] = input[frame * channels + channel] }
            for frame in available..<frames { target[frame] = 0 }
        }
        input.removeFirst(available * channels)
        return noErr
    }
}
