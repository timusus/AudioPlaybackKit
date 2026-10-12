import AVFoundation
import CoreMedia

/// The device's audio output: one `AVSampleBufferAudioRenderer` on an
/// `AVSampleBufferRenderSynchronizer`, mapped one to one onto `AudioOutput`. Every rule lives in
/// the core above it (ADR-0018).
///
/// It never configures or activates `AVAudioSession`: on iOS the app owns the category, activation
/// and interruptions. `.stalled` is never sent: the renderer has no signal for it, since an underrun
/// runs the clock on silently (ADR-0018). A failed renderer is reported from its `status` and by
/// the next enqueue; on iOS a media-services reset is reported as `.mediaServicesReset`.
final class SampleBufferAudioOutput: AudioOutput, @unchecked Sendable {
    private let formats = FormatDescriptionCache()
    // Recursive: events go to the handler under it, and a handler may read the clock.
    private let lock = NSRecursiveLock()
    // Under `lock`: `rebuild()` replaces the renderer and its synchronizer, and its observers.
    private var _renderer: AVSampleBufferAudioRenderer
    private var _synchronizer: AVSampleBufferRenderSynchronizer
    private var observers = Observers()
    private var settings: RendererSettings
    private var handler: (@Sendable (AudioOutputEvent) -> Void)?
    #if os(iOS)
    private var resetObserver: (any NSObjectProtocol)?
    #endif

    init(timePitchAlgorithm: AVAudioTimePitchAlgorithm = .timeDomain) {
        settings = RendererSettings(timePitchAlgorithm: timePitchAlgorithm)
        (_renderer, _synchronizer) = settings.makeRenderer()
        observers = observe(_renderer)
        #if os(iOS)
        // The audio objects must be recreated after a reset (AVAudioSession docs).
        resetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil
        ) { [weak self] _ in
            // The notification names no renderer, so it skips `send`'s identity guard.
            self?.lock.withLock { self?.handler?(.mediaServicesReset) }
        }
        #endif
    }

    deinit {
        observers.remove()
        #if os(iOS)
        if let resetObserver { NotificationCenter.default.removeObserver(resetObserver) }
        #endif
    }

    /// The renderer playing now.
    var renderer: AVSampleBufferAudioRenderer { lock.withLock { _renderer } }
    private var synchronizer: AVSampleBufferRenderSynchronizer { lock.withLock { _synchronizer } }

    func enqueue(_ samples: [Float], format: PCMFormat, at time: TimeInterval) throws {
        let buffer = try makeSampleBuffer(
            samples, description: formats.description(for: format),
            presentationTime: presentationTime(time, sampleRate: format.sampleRate)
        )
        let renderer = renderer
        renderer.enqueue(buffer)
        if renderer.status == .failed { throw AudioOutputError.rendererFailed }
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
        lock.withLock { settings.volume = volume }
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

    /// A fresh renderer on a fresh synchronizer: Apple does not say whether a synchronizer survives
    /// a media-services reset, and a new one costs little.
    func rebuild() throws {
        let (renderer, synchronizer) = lock.withLock { settings }.makeRenderer()
        if renderer.status == .failed { throw renderer.error ?? AudioOutputError.rendererFailed }
        let observers = observe(renderer)
        let old = lock.withLock {
            defer { (_renderer, _synchronizer, self.observers) = (renderer, synchronizer, observers) }
            return (renderer: _renderer, synchronizer: _synchronizer, observers: self.observers)
        }
        old.observers.remove()
        old.synchronizer.removeRenderer(old.renderer, at: old.synchronizer.currentTime())
    }

    func setEventHandler(_ handler: @escaping @Sendable (AudioOutputEvent) -> Void) {
        lock.withLock { self.handler = handler }
    }

    #if os(macOS)
    /// Tests only: a device switch mid-play is a documented auto-flush trigger, which a test can
    /// drive on macOS without a human.
    var audioOutputDeviceUniqueID: String? {
        get { renderer.audioOutputDeviceUniqueID }
        set {
            lock.withLock { settings.deviceUniqueID = newValue }
            renderer.audioOutputDeviceUniqueID = newValue
        }
    }
    #endif

    private func observe(_ renderer: AVSampleBufferAudioRenderer) -> Observers {
        let autoFlush = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: renderer, queue: nil
        ) { [weak self, weak renderer] note in
            guard let self, let renderer else { return }
            let flushTime = (note.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?.timeValue
            send(.autoFlushed(at: flushTime?.seconds ?? currentTime()), from: renderer)
        }
        // Apple's answer to a new configuration (e.g. spatial audio) is to flush and re-enqueue from
        // what is heard, the same restart as an auto-flush; the renderer itself is fine.
        let configurationChange = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferAudioRendererOutputConfigurationDidChange,
            object: renderer, queue: nil
        ) { [weak self, weak renderer] _ in
            guard let self, let renderer else { return }
            send(.autoFlushed(at: currentTime() - outputLatency), from: renderer)
        }
        let status = renderer.observe(\.status) { [weak self] renderer, _ in
            guard renderer.status == .failed else { return }
            self?.send(.failed(renderer.error ?? AudioOutputError.rendererFailed), from: renderer)
        }
        return Observers(notifications: [autoFlush, configurationChange], status: status)
    }

    /// Under `lock`, which `rebuild()` swaps under, so nothing from a replaced renderer reaches the
    /// handler once `rebuild()` returns.
    private func send(_ event: AudioOutputEvent, from renderer: AVSampleBufferAudioRenderer) {
        lock.withLock {
            guard renderer === _renderer else { return }
            handler?(event)
        }
    }
}

/// What the output keeps across a rebuild.
private struct RendererSettings {
    let timePitchAlgorithm: AVAudioTimePitchAlgorithm
    var volume: Float = 1
    #if os(macOS)
    var deviceUniqueID: String?
    #endif

    func makeRenderer() -> (AVSampleBufferAudioRenderer, AVSampleBufferRenderSynchronizer) {
        let renderer = AVSampleBufferAudioRenderer()
        // Always set: the iOS default (lowQualityZeroLatency) is wrong for speech.
        renderer.audioTimePitchAlgorithm = timePitchAlgorithm
        renderer.volume = volume
        #if os(macOS)
        // Nil is the system default already, and setting it raises.
        if let deviceUniqueID { renderer.audioOutputDeviceUniqueID = deviceUniqueID }
        #endif
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.addRenderer(renderer)
        return (renderer, synchronizer)
    }
}

private struct Observers {
    var notifications: [any NSObjectProtocol] = []
    var status: NSKeyValueObservation?

    func remove() {
        notifications.forEach(NotificationCenter.default.removeObserver)
        status?.invalidate()
    }
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
