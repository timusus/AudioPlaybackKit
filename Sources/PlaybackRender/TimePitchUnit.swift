import Accelerate
import AudioToolbox

// UnsafeMutableAudioBufferListPointer comes from this overlay on iOS; macOS finds it without.
import AVFoundation

/// Apple's AUNewTimePitch, the unit behind `AVAudioUnitTimePitch`, rendered on the caller's thread.
/// The exact pull and the lag were measured at 0.5-4x, 44.1 and 48 kHz and any block size, while
/// the unit reports a latency of 0.
final class TimePitchUnit: StretchUnit {
    let window = 2048

    private let channels: Int
    var rate: Double = 1 {
        didSet { AudioUnitSetParameter(unit, kNewTimePitchParam_Rate, kAudioUnitScope_Global, 0, AudioUnitParameterValue(rate), 0) }
    }

    private let unit: AudioUnit
    private let output: UnsafeMutableAudioBufferListPointer
    private var input: [Float] = []
    private var inputStart = 0
    private var sampleTime = 0.0

    private static let maximumFrames = 8192

    init(format: PCMFormat) {
        channels = format.channelCount
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_FormatConverter, componentSubType: kAudioUnitSubType_NewTimePitch,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
        )
        var instance: AudioUnit?
        // A system unit present on every supported OS: failing here means the OS is broken.
        guard let component = AudioComponentFindNext(nil, &description),
              AudioComponentInstanceNew(component, &instance) == noErr, let instance else {
            fatalError("AUNewTimePitch is unavailable")
        }
        unit = instance
        output = AudioBufferList.allocate(maximumBuffers: channels)
        for channel in 0..<channels {
            output[channel] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0,
                                          mData: UnsafeMutableRawPointer.allocate(byteCount: Self.maximumFrames * 4, alignment: 16))
        }
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
            Unmanaged<TimePitchUnit>.fromOpaque(refCon).takeUnretainedValue().pull(Int(frames), into: data!)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                             &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        AudioUnitInitialize(unit)
    }

    deinit {
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        for buffer in output { buffer.mData?.deallocate() }
        output.unsafeMutablePointer.deallocate()
    }

    var queuedFrames: Int { (input.count - inputStart) / channels }

    func append(_ samples: [Float]) {
        // Drop the consumed head only once it is the bigger half, so each sample moves O(1) times.
        if inputStart == input.count {
            input.removeAll(keepingCapacity: true)
            inputStart = 0
        } else if inputStart > input.count / 2 {
            input.removeFirst(inputStart)
            inputStart = 0
        }
        input += samples
    }

    func render(_ frames: Int) -> [Float] {
        [Float](unsafeUninitializedCapacity: frames * channels) { buffer, count in
            var done = 0
            while done < frames {
                let slice = min(frames - done, Self.maximumFrames)
                renderSlice(slice, into: buffer.baseAddress! + done * channels)
                done += slice
            }
            count = frames * channels
        }
    }

    private func renderSlice(_ frames: Int, into target: UnsafeMutablePointer<Float>) {
        for channel in 0..<channels { output[channel].mDataByteSize = UInt32(frames * 4) }
        var flags = AudioUnitRenderActionFlags()
        var time = AudioTimeStamp()
        time.mSampleTime = sampleTime
        time.mFlags = .sampleTimeValid
        sampleTime += Double(frames)
        AudioUnitRender(unit, &flags, &time, 0, UInt32(frames), output.unsafeMutablePointer)
        for channel in 0..<channels {
            cblas_scopy(Int32(frames), output[channel].mData!.assumingMemoryBound(to: Float.self), 1,
                        target + channel, Int32(channels))
        }
    }

    private func pull(_ frames: Int, into data: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(data)
        let available = min(frames, queuedFrames)
        input.withUnsafeBufferPointer { samples in
            for channel in 0..<channels {
                let target = buffers[channel].mData!.assumingMemoryBound(to: Float.self)
                if available > 0 {
                    cblas_scopy(Int32(available), samples.baseAddress! + inputStart + channel, Int32(channels), target, 1)
                }
                (target + available).update(repeating: 0, count: frames - available)
            }
        }
        inputStart += available * channels
        return noErr
    }
}
