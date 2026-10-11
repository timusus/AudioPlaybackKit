import AVFoundation
import CoreMedia

/// The device's audio output: one `AVSampleBufferAudioRenderer` on an
/// `AVSampleBufferRenderSynchronizer`, mapped one to one onto `AudioOutput`. Every rule lives in
/// the core above it (ADR-0018).
///
/// It never configures or activates `AVAudioSession`: on iOS the app owns the category, activation
/// and interruptions. `.stalled` is never sent: the renderer has no signal for it, since an underrun
/// runs the clock on silently (ADR-0018) and a failed renderer surfaces on the next enqueue.
final class SampleBufferAudioOutput: AudioOutput, @unchecked Sendable {
    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let formats = FormatDescriptionCache()
    private let lock = NSLock()
    private var handler: (@Sendable (AudioOutputEvent) -> Void)?
    private var observer: (any NSObjectProtocol)?

    init() {
        // The iOS default (lowQualityZeroLatency) is wrong for speech; timeDomain had the shortest
        // dropout on a rate change on the iPhone probe (97 ms to 2x, 140 ms back).
        renderer.audioTimePitchAlgorithm = .timeDomain
        synchronizer.addRenderer(renderer)
        observer = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: renderer, queue: nil
        ) { [weak self] note in
            guard let self else { return }
            let flushTime = (note.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?.timeValue
            let time = flushTime?.seconds ?? currentTime()
            lock.withLock { self.handler }?(.autoFlushed(at: time))
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func enqueue(_ samples: [Float], format: PCMFormat, at time: TimeInterval) throws {
        let buffer = try makeSampleBuffer(
            samples, description: formats.description(for: format),
            presentationTime: presentationTime(time, sampleRate: format.sampleRate)
        )
        renderer.enqueue(buffer)
        if renderer.status == .failed { throw AudioOutputError.formatRejected(format) }
    }

    func flush() {
        renderer.flush()
    }

    func setRate(_ rate: Double, at time: TimeInterval?) {
        if let time {
            synchronizer.setRate(Float(rate), time: anchorTime(time))
        } else {
            synchronizer.rate = Float(rate)
        }
    }

    func setVolume(_ volume: Float) {
        renderer.volume = volume
    }

    func currentTime() -> TimeInterval {
        synchronizer.currentTime().seconds
    }

    var outputLatency: TimeInterval {
        #if os(iOS)
        // Read per call: it changes with the route. The iPhone probe heard currentTime 11 ms ahead
        // with outputLatency at 9.7 ms (ADR-0018).
        AVAudioSession.sharedInstance().outputLatency
        #else
        // The macOS clock already includes the output latency (ADR-0018).
        0
        #endif
    }

    var isReadyForMoreData: Bool {
        renderer.isReadyForMoreMediaData
    }

    func setEventHandler(_ handler: @escaping @Sendable (AudioOutputEvent) -> Void) {
        lock.withLock { self.handler = handler }
    }

    #if os(macOS)
    /// Tests only: a device switch mid-play is a documented auto-flush trigger, which a test can
    /// drive on macOS without a human.
    var audioOutputDeviceUniqueID: String? {
        get { renderer.audioOutputDeviceUniqueID }
        set { renderer.audioOutputDeviceUniqueID = newValue }
    }
    #endif
}

/// `time` in nanoseconds, since an anchor is a clock reading or a written end at any item's rate.
/// Rounded up so the clock reads back at least `time`: the feeder pauses an underrun at the written
/// end and waits for the clock to reach it, which a nanosecond short never does.
func anchorTime(_ time: TimeInterval) -> CMTime {
    var nanoseconds = CMTimeValue((time * 1e9).rounded(.up))
    if Double(nanoseconds) / 1e9 < time { nanoseconds += 1 }
    return CMTime(value: nanoseconds, timescale: 1_000_000_000)
}

/// `time` as a frame count in the buffer's own sample-rate timescale. Rounded to a frame, so a
/// buffer stamped at the previous one's end in the same format joins with no gap or overlap.
func presentationTime(_ time: TimeInterval, sampleRate: Double) -> CMTime {
    CMTime(value: CMTimeValue((time * sampleRate).rounded()), timescale: CMTimeScale(sampleRate))
}

/// One `CMAudioFormatDescription` per format, so a long run of buffers shares one description.
final class FormatDescriptionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptions: [PCMFormat: CMAudioFormatDescription] = [:]

    func description(for format: PCMFormat) throws -> CMAudioFormatDescription {
        try lock.withLock {
            if let description = descriptions[format] { return description }
            let description = try makeFormatDescription(format)
            descriptions[format] = description
            return description
        }
    }
}

/// The decoder's channel order above stereo (FFmpeg's default layout for the count); unlabelled
/// discrete channels would play centre and LFE as plain left/right.
private let ffmpegDefaultLabels: [Int: [AudioChannelLabel]] = [
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

/// Packed Float32 interleaved LPCM, the decoder's output (ADR-0010).
func makeFormatDescription(_ format: PCMFormat) throws -> CMAudioFormatDescription {
    let bytesPerFrame = UInt32(MemoryLayout<Float>.size * format.channelCount)
    var asbd = AudioStreamBasicDescription(
        mSampleRate: format.sampleRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
        mChannelsPerFrame: UInt32(format.channelCount), mBitsPerChannel: 32, mReserved: 0
    )
    let labels = ffmpegDefaultLabels[format.channelCount] ?? []
    let layoutSize = AudioChannelLayout.sizeInBytes(maximumDescriptions: max(labels.count, 1))
    let raw = UnsafeMutableRawPointer.allocate(byteCount: layoutSize, alignment: MemoryLayout<AudioChannelLayout>.alignment)
    defer { raw.deallocate() }
    raw.initializeMemory(as: UInt8.self, repeating: 0, count: layoutSize)
    let layout = raw.bindMemory(to: AudioChannelLayout.self, capacity: 1)
    switch format.channelCount {
    case 1: layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
    case 2: layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
    case _ where !labels.isEmpty:
        layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
        layout.pointee.mNumberChannelDescriptions = UInt32(labels.count)
        let descriptions = (raw + MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!)
            .assumingMemoryBound(to: AudioChannelDescription.self)
        for (index, label) in labels.enumerated() { descriptions[index].mChannelLabel = label }
    default: layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(format.channelCount)
    }
    var description: CMAudioFormatDescription?
    let status = CMAudioFormatDescriptionCreate(
        allocator: nil, asbd: &asbd, layoutSize: layoutSize, layout: layout,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description
    )
    guard status == noErr, let description else { throw osStatusError(status) }
    return description
}

/// Copies `samples` into one ready sample buffer of `samples.count / channels` frames.
func makeSampleBuffer(
    _ samples: [Float], description: CMAudioFormatDescription, presentationTime: CMTime
) throws -> CMSampleBuffer {
    let channels = Int(description.audioStreamBasicDescription?.mChannelsPerFrame ?? 1)
    let bytes = samples.count * MemoryLayout<Float>.size
    var block: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
        allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
        offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
    )
    guard status == noErr, let block else { throw osStatusError(status) }
    status = samples.withUnsafeBytes {
        CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
    }
    guard status == noErr else { throw osStatusError(status) }
    var buffer: CMSampleBuffer?
    status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: nil, dataBuffer: block, formatDescription: description,
        sampleCount: samples.count / channels, presentationTimeStamp: presentationTime,
        packetDescriptions: nil, sampleBufferOut: &buffer
    )
    guard status == noErr, let buffer else { throw osStatusError(status) }
    return buffer
}

private func osStatusError(_ status: OSStatus) -> NSError {
    NSError(domain: NSOSStatusErrorDomain, code: Int(status))
}
