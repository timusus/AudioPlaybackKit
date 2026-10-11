import CoreMedia
import Foundation

/// The test signal at media time `t`. Every signal is a function of absolute media time, so a join
/// between segments is phase-continuous and any glitch heard there came from the output path.
typealias Signal = @Sendable (_ t: Double, _ channel: Int, _ segment: Int) -> Float

struct Segment {
    let pts: Double
    let duration: Double
    let rate: Double
    let channels: Int
}

enum Signals {
    static func sine(_ hz: Double, _ amplitude: Float = 0.15) -> Signal {
        { t, _, _ in amplitude * Float(sin(2 * .pi * hz * t)) }
    }

    /// A short tick at every whole media second.
    static let click: Signal = { t, _, _ in
        let f = t - t.rounded(.down)
        return f < 0.02 ? 0.8 * Float(sin(2 * .pi * 1800 * f) * exp(-f * 250)) : 0
    }

    /// 400 -> 4000 Hz sweep over 200 ms centred on each join.
    static func chirps(at joins: [Double]) -> Signal {
        { t, _, _ in
            for join in joins {
                let tau = t - (join - 0.1)
                if tau >= 0, tau < 0.2 { return 0.25 * Float(sin(2 * .pi * (400 * tau + 0.5 * (3600 / 0.2) * tau * tau))) }
            }
            return 0
        }
    }

    static func mix(_ parts: Signal...) -> Signal {
        { t, channel, segment in parts.reduce(0) { $0 + $1(t, channel, segment) } }
    }

    static func stream(_ signal: @escaping Signal, rate: Double = 44100, seconds: Double = 1800) -> Feeder {
        Feeder([Segment(pts: 0, duration: seconds, rate: rate, channels: 2)], signal)
    }
}

/// Renders segments lazily into 100 ms sample buffers, in order; `rewind` re-enters the plan after a flush.
final class Feeder: @unchecked Sendable {
    private let segments: [Segment]
    private let signal: Signal
    private let lock = NSLock()
    private var index = 0
    private var frame = 0
    private var _end = 0.0

    init(_ segments: [Segment], _ signal: @escaping Signal) {
        self.segments = segments
        self.signal = signal
    }

    /// Media time at the end of the last buffer handed out.
    var end: Double { lock.withLock { _end } }

    func next() -> CMSampleBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard index < segments.count else { return nil }
        let segment = segments[index]
        let total = Int(segment.duration * segment.rate)
        let count = min(Int(segment.rate / 10), total - frame)
        var samples: [Float] = []
        samples.reserveCapacity(count * segment.channels)
        for f in 0..<count {
            let t = segment.pts + Double(frame + f) / segment.rate
            for channel in 0..<segment.channels { samples.append(signal(t, channel, index)) }
        }
        let pts = CMTime(value: CMTimeValue((segment.pts * segment.rate).rounded()) + CMTimeValue(frame), timescale: CMTimeScale(segment.rate))
        let buffer = try? makeSampleBuffer(samples[...], sampleRate: segment.rate, channelCount: segment.channels, pts: pts)
        frame += count
        _end = segment.pts + Double(frame) / segment.rate
        if frame >= total {
            index += 1
            frame = 0
        }
        return buffer
    }

    func rewind(to t: Double) {
        lock.withLock {
            guard let i = segments.firstIndex(where: { $0.pts + $0.duration > t }) else {
                index = segments.count
                return
            }
            index = i
            frame = max(0, Int(((t - segments[i].pts) * segments[i].rate).rounded(.down)))
            _end = segments[i].pts + Double(frame) / segments[i].rate
        }
    }
}

enum ProbeError: Error { case status(String, OSStatus) }

/// Interleaved Float32 as an LPCM CMSampleBuffer. Copied from RenderProbeKit, which is macOS-only
/// and pulls in the FFmpeg decoder this app does not need.
func makeSampleBuffer(_ samples: ArraySlice<Float>, sampleRate: Double, channelCount: Int, pts: CMTime) throws -> CMSampleBuffer {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: UInt32(4 * channelCount), mFramesPerPacket: 1,
        mBytesPerFrame: UInt32(4 * channelCount), mChannelsPerFrame: UInt32(channelCount),
        mBitsPerChannel: 32, mReserved: 0
    )
    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag = channelCount == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
    var format: CMAudioFormatDescription?
    var status = CMAudioFormatDescriptionCreate(
        allocator: nil, asbd: &asbd, layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
    )
    guard status == noErr, let format else { throw ProbeError.status("format", status) }

    let bytes = samples.count * 4
    var block: CMBlockBuffer?
    status = CMBlockBufferCreateWithMemoryBlock(
        allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
        offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
    )
    guard status == noErr, let block else { throw ProbeError.status("block", status) }
    status = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
    guard status == noErr else { throw ProbeError.status("copy", status) }

    var buffer: CMSampleBuffer?
    status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: nil, dataBuffer: block, formatDescription: format,
        sampleCount: samples.count / channelCount, presentationTimeStamp: pts,
        packetDescriptions: nil, sampleBufferOut: &buffer
    )
    guard status == noErr, let buffer else { throw ProbeError.status("sample buffer", status) }
    return buffer
}
