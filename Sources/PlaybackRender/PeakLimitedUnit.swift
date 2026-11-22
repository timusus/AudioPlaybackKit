import Foundation

/// A stretch whose output never passes -1 dBFS. Overlapping a stretch's frames rebuilds the peaks a
/// limiter before it took off, so its output is limited again here, after the unit.
///
/// A lookahead limiter, its gain linked across channels: a frame's gain is the mean of the last
/// `lookahead + 1` release-smoothed minima of the gain each frame needs, and each of those minima
/// covers the frame, so no frame keeps more gain than it can take. The lookahead joins the unit's lag.
final class PeakLimitedUnit: StretchUnit {
    /// What a limiter before the stretch leaves, with room for inter-sample peaks.
    static let ceiling = Float(pow(10, -1.0 / 20))
    // A hair under, so the gain's rounding never lands a sample over.
    private static let limit = ceiling * 0.9999

    private let base: any StretchUnit
    private let channels: Int
    private let lookahead: Int
    private let release: Float
    private var frame = 0
    /// The needed gains of the last `lookahead + 1` frames that a later frame does not undercut, ascending.
    private var minimaFrames: [Int] = [], minimaGains: [Float] = []
    private var minimaStart = 0
    private var smoothed: Float = 1
    private var gains: [Float]
    private var gainSum: Double
    private var gainCursor = 0
    private var delay: [Float]
    private var delayCursor = 0

    init(_ base: any StretchUnit, format: PCMFormat) {
        self.base = base
        channels = format.channelCount
        lookahead = max(Int((format.sampleRate * 0.005).rounded()), 1)
        release = Float(exp(-1 / (0.05 * format.sampleRate)))
        gains = [Float](repeating: 1, count: lookahead + 1)
        gainSum = Double(lookahead + 1)
        delay = [Float](repeating: 0, count: lookahead * channels)
    }

    var rate: Double {
        get { base.rate }
        set { base.rate = newValue }
    }

    var queuedFrames: Int { base.queuedFrames }

    func lag(_ rate: Double) -> Int { base.lag(rate) + lookahead }

    func append(_ samples: [Float]) { base.append(samples) }

    func render(_ frames: Int) -> [Float] {
        var samples = base.render(frames)
        for start in stride(from: 0, to: samples.count, by: channels) {
            var peak: Float = 0
            for channel in 0..<channels {
                peak = max(peak, abs(samples[start + channel]))
            }
            let gain = gain(needed: peak > Self.limit ? Self.limit / peak : 1)
            let delayed = delayCursor * channels
            for channel in 0..<channels {
                let sample = samples[start + channel]
                samples[start + channel] = delay[delayed + channel] * gain
                delay[delayed + channel] = sample
            }
            delayCursor = (delayCursor + 1) % lookahead
        }
        return samples
    }

    /// The gain for the frame `lookahead` frames back, given what the newest frame needs.
    private func gain(needed: Float) -> Float {
        while minimaGains.count > minimaStart, minimaGains[minimaGains.count - 1] >= needed {
            minimaGains.removeLast()
            minimaFrames.removeLast()
        }
        minimaGains.append(needed)
        minimaFrames.append(frame)
        while minimaFrames[minimaStart] < frame - lookahead {
            minimaStart += 1
        }
        if minimaStart > minimaGains.count / 2 {
            minimaGains.removeFirst(minimaStart)
            minimaFrames.removeFirst(minimaStart)
            minimaStart = 0
        }
        frame += 1
        smoothed = min(minimaGains[minimaStart], 1 - release * (1 - smoothed))
        gainSum += Double(smoothed) - Double(gains[gainCursor])
        gains[gainCursor] = smoothed
        gainCursor = (gainCursor + 1) % gains.count
        return Float(gainSum / Double(gains.count))
    }
}
