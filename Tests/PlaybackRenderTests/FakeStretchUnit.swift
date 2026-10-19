@testable import PlaybackRender

/// A stretch that keeps each sample whole, for fakes whose sample values name their frame: each
/// output frame is the first input frame its pull reaches, so 2x keeps every other frame and 0.5x
/// plays each twice. It pulls exactly as the real unit does, without its lag.
final class FakeStretchUnit: StretchUnit {
    static func stretch() -> TimeStretch { TimeStretch { FakeStretchUnit(channels: $0.channelCount) } }

    var rate: Double = 1
    let window = 0
    private let channels: Int
    private var input: [Float] = []
    /// Input frames pulled, whole and fractional; the whole ones are dropped from `input`.
    private var position = 0.0

    init(channels: Int) {
        self.channels = channels
    }

    var queuedFrames: Int { max(input.count / channels - Int(position), 0) }

    func append(_ samples: [Float]) {
        input += samples
    }

    func render(_ frames: Int) -> [Float] {
        var samples: [Float] = []
        for _ in 0..<frames {
            let start = Int(position) * channels
            if start < input.count {
                samples += input[start..<(start + channels)]
            } else {
                samples += [Float](repeating: 0, count: channels)
            }
            position += rate
        }
        let whole = min(Int(position), input.count / channels)
        input.removeFirst(whole * channels)
        position -= Double(whole)
        return samples
    }
}
