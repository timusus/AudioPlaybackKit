// Ported from androidx/media3 `common/audio/Sonic.java` (the speed path only), itself from Bill Cox's
// Sonic library. Copyright (C) 2017 The Android Open Source Project, Copyright 2010 Bill Cox.
// Licensed under the Apache License, Version 2.0: http://www.apache.org/licenses/LICENSE-2.0

import Foundation

/// Pitch-preserving speed change by pitch-synchronous overlap-add, as media3's `SonicAudioProcessor`
/// applies playback speed. Interleaved Float32; deviates from media3 only in sample type, so the
/// period search averages floats where media3 averages shorts.
struct Sonic {
    /// Takes effect from the frames not yet consumed. Within 1e-5 of 1 every buffered frame is copied.
    var speed: Double

    private let channels: Int
    private let minPeriod: Int
    private let maxPeriod: Int
    private let maxRequired: Int
    private let skip: Int
    private var input: [Float] = []
    private var downsampled: [Float]
    private var remainingInputToCopy = 0
    /// media3's `accumulatedSpeedAdjustmentError`.
    private var speedError = 0.0
    private var prevPeriod = 0
    private var prevMinDiff: Float = 0
    private var minDiff: Float = 0
    private var maxDiff: Float = 0

    init(sampleRate: Double, channels: Int, speed: Double) {
        let rate = Int(sampleRate)
        self.speed = speed
        self.channels = channels
        minPeriod = max(1, rate / 400)
        maxPeriod = max(minPeriod + 1, rate / 65)
        maxRequired = 2 * maxPeriod
        skip = rate > 4000 ? rate / 4000 : 1
        downsampled = [Float](repeating: 0, count: maxRequired)
    }

    /// Input frames held until enough follow to find a pitch period.
    var bufferedFrames: Int { input.count / channels }

    mutating func process(_ samples: [Float]) -> [Float] {
        input += samples
        var output: [Float] = []
        output.reserveCapacity(Int(Double(input.count) / speed) + maxRequired * channels)
        processInput(into: &output)
        return output
    }

    /// Flushes what is buffered with silence and trims the output to the buffered frames at `speed`.
    mutating func finish() -> [Float] {
        let expected = Int(Double(bufferedFrames) / speed + 0.5)
        input += repeatElement(0, count: 2 * maxRequired * channels)
        var output: [Float] = []
        processInput(into: &output)
        if output.count > expected * channels {
            output.removeSubrange((expected * channels)...)
        }
        input.removeAll(keepingCapacity: true)
        remainingInputToCopy = 0
        return output
    }

    private mutating func processInput(into output: inout [Float]) {
        guard abs(speed - 1) >= 1e-5 else {
            output += input
            input.removeAll(keepingCapacity: true)
            return
        }
        let frames = bufferedFrames
        guard frames >= maxRequired else { return }
        var position = 0
        repeat {
            if remainingInputToCopy > 0 {
                let count = min(maxRequired, remainingInputToCopy)
                output += input[(position * channels)..<((position + count) * channels)]
                remainingInputToCopy -= count
                position += count
            } else {
                let period = findPitchPeriod(at: position)
                if speed > 1 {
                    position += period + skipPitchPeriod(at: position, period: period, into: &output)
                } else {
                    position += insertPitchPeriod(at: position, period: period, into: &output)
                }
            }
        } while position + maxRequired <= frames
        input.removeFirst(position * channels)
    }

    /// Writes one period cross-faded into the next and returns the frames it stands for beyond `period`.
    private mutating func skipPitchPeriod(at position: Int, period: Int, into output: inout [Float]) -> Int {
        let newFrames: Int
        if speed >= 2 {
            newFrames = rounded(Double(period) / (speed - 1))
        } else {
            newFrames = period
            remainingInputToCopy = rounded(Double(period) * (2 - speed) / (speed - 1))
        }
        let start = output.count / channels
        output += repeatElement(0, count: newFrames * channels)
        overlapAdd(newFrames, into: &output, at: start, down: position, up: position + period)
        return newFrames
    }

    /// Writes a period then that period again cross-faded back, and returns the input frames consumed.
    private mutating func insertPitchPeriod(at position: Int, period: Int, into output: inout [Float]) -> Int {
        let newFrames: Int
        if speed < 0.5 {
            newFrames = rounded(Double(period) * speed / (1 - speed))
        } else {
            newFrames = period
            remainingInputToCopy = rounded(Double(period) * (2 * speed - 1) / (1 - speed))
        }
        output += input[(position * channels)..<((position + period) * channels)]
        let start = output.count / channels
        output += repeatElement(0, count: newFrames * channels)
        overlapAdd(newFrames, into: &output, at: start, down: position + period, up: position)
        return newFrames
    }

    /// Whole frames, carrying the rounding into the next period so the speed holds over time.
    private mutating func rounded(_ expected: Double) -> Int {
        let frames = expected + speedError
        let whole = Int(frames.rounded())
        speedError = frames - Double(whole)
        return whole
    }

    private func overlapAdd(_ frames: Int, into output: inout [Float], at outFrame: Int, down: Int, up: Int) {
        let channels = channels
        input.withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { output in
                for channel in 0..<channels {
                    var o = outFrame * channels + channel
                    var d = down * channels + channel
                    var u = up * channels + channel
                    for t in 0..<frames {
                        output[o] = (input[d] * Float(frames - t) + input[u] * Float(t)) / Float(frames)
                        o += channels
                        d += channels
                        u += channels
                    }
                }
            }
        }
    }

    private mutating func findPitchPeriod(at position: Int) -> Int {
        downsample(at: position, skip: skip)
        var period = findPitchPeriodInRange(minPeriod / skip, maxPeriod / skip)
        if skip != 1 {
            period *= skip
            downsample(at: position, skip: 1)
            period = findPitchPeriodInRange(max(period - skip * 4, minPeriod), min(period + skip * 4, maxPeriod))
        }
        let chosen = previousPeriodBetter() ? prevPeriod : period
        prevMinDiff = minDiff
        prevPeriod = period
        return chosen
    }

    /// Averages `skip` frames of every channel into one value, over the frames a period search reads.
    private mutating func downsample(at position: Int, skip: Int) {
        let count = maxRequired / skip
        let perValue = channels * skip
        input.withUnsafeBufferPointer { input in
            downsampled.withUnsafeMutableBufferPointer { values in
                var sample = position * channels
                for index in 0..<count {
                    var sum: Float = 0
                    for _ in 0..<perValue {
                        sum += input[sample]
                        sample += 1
                    }
                    values[index] = sum / Float(perValue)
                }
            }
        }
    }

    /// The average magnitude difference function: the period whose two copies differ least per frame.
    private mutating func findPitchPeriodInRange(_ lower: Int, _ upper: Int) -> Int {
        var best = 0, worst = 255
        var minDiff: Float = 1, maxDiff: Float = 0
        downsampled.withUnsafeBufferPointer { values in
            for period in lower...upper {
                var diff: Float = 0
                for index in 0..<period {
                    diff += abs(values[index] - values[period + index])
                }
                if diff * Float(best) < minDiff * Float(period) {
                    minDiff = diff
                    best = period
                }
                if diff * Float(worst) > maxDiff * Float(period) {
                    maxDiff = diff
                    worst = period
                }
            }
        }
        self.minDiff = minDiff / Float(best)
        self.maxDiff = maxDiff / Float(worst)
        return best
    }

    private func previousPeriodBetter() -> Bool {
        guard minDiff != 0, prevPeriod != 0 else { return false }
        if maxDiff > minDiff * 3 { return false }
        if minDiff * 2 <= prevMinDiff * 3 { return false }
        return true
    }
}
