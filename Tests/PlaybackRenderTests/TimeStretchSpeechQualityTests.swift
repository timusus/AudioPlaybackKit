import AudioToolbox
import AVFoundation
import PlaybackDecode
@testable import PlaybackRender
import XCTest

/// Speech through `TimeStretch` at podcast speeds, scored by STOI against the source through the ideal
/// time map, and counted for samples over the -1 dBFS ceiling the app's limiter leaves before the stretch.
/// `STRETCH_QUALITY=1` prints the comparison table (units, settings, ffmpeg `atempo`, Rubber Band) the
/// choice of unit rests on (ADR-0030).
final class TimeStretchSpeechQualityTests: XCTestCase {
    /// 10 s of a public-domain LibriVox reading (The Art of War, chapter 1), 96 kbps mono MP3.
    private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Speech/speech.mp3")
    private static let ceiling = Float(pow(10, -1.0 / 20))
    private static let sampleRate = 44100.0
    private static let rates = [1.25, 1.5, 2]

    /// The fixture scaled so its peak sits at the ceiling, as a limiter before the stretch leaves it.
    private static func speech() throws -> [Float] {
        try XCTSkipUnless(FFmpegStreamDecoder.isAvailable)
        let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: fixture))
        _ = try decoder.open()
        var samples: [Float] = []
        while let chunk = decoder.nextChunk() {
            samples += chunk
        }
        let peak = samples.map(abs).max()!
        return samples.map { $0 * ceiling / peak }
    }

    /// Through `TimeStretch` and its limiter in tenth-of-a-second chunks, as the feeder drives it.
    private static func stretched(_ samples: [Float], rate: Double, algorithm: TimePitchUnit.Algorithm) -> [Float] {
        let format = PCMFormat(sampleRate: sampleRate, channelCount: 1)
        var stretch = TimeStretch { PeakLimitedUnit(TimePitchUnit(format: $0, algorithm: algorithm), format: $0) }
        var output: [Float] = []
        for start in stride(from: 0, to: samples.count, by: 4410) {
            let slice = Array(samples[start..<min(start + 4410, samples.count)])
            let tag = SegmentTag(item: 1, mediaStartFrame: Int64(start), frameCount: Int64(slice.count))
            output += stretch.process(TaggedChunk(samples: slice, format: format, tags: [tag]), rate: rate).flatMap(\.samples)
        }
        return output + stretch.finish().flatMap(\.samples)
    }

    /// Straight through the unit in 512-frame renders: `ipto` makes its output in 512-frame blocks and
    /// pulls a whole block's input at once, so `TimeStretch`'s renders of any length make it read past
    /// the queue (silence) mid-stream.
    private static func blockRendered(_ samples: [Float], rate: Double, algorithm: TimePitchUnit.Algorithm) -> [Float] {
        let unit = TimePitchUnit(format: PCMFormat(sampleRate: sampleRate, channelCount: 1), algorithm: algorithm)
        unit.rate = rate
        unit.append(samples + [Float](repeating: 0, count: Int(sampleRate)))
        var output: [Float] = []
        while Double(unit.queuedFrames) > 512 * rate + 1 {
            output += unit.render(512)
        }
        return Array(output.prefix(Int(Double(samples.count) / rate)))
    }

    private static func overCeiling(_ samples: [Float]) -> Int {
        samples.count { abs($0) > ceiling }
    }

    /// With transient preservation on, the default, the unit scored .909/.836/.729 at 1.25/1.5/2x;
    /// Rubber Band R3 scores .932/.902/.847.
    func testSpeechKeepsItsEnvelopesAtEveryPodcastSpeed() throws {
        let source = try Self.speech()
        let source10k = SpeechIntelligibility.resample(source, from: Self.sampleRate)
        for rate in Self.rates {
            let output = Self.stretched(source, rate: rate, algorithm: .spectral)
            let score = SpeechIntelligibility.score(reference: source10k, processed: SpeechIntelligibility.resample(output, from: Self.sampleRate), rate: rate)
            XCTAssertGreaterThan(score, 0.85, "rate \(rate)")
        }
    }

    /// Speech driven 12 dB into the ceiling, as loud programme leaves a limiter: the stretch's overlaps
    /// rebuild peaks over it.
    func testStretchedLoudSpeechStaysUnderTheCeiling() throws {
        let loud = try Self.speech().map { min(max($0 * 4, -Self.ceiling), Self.ceiling) }
        for rate in [0.75] + Self.rates + [3] {
            let output = Self.stretched(loud, rate: rate, algorithm: .spectral)
            XCTAssertEqual(Self.overCeiling(output), 0, "rate \(rate)")
        }
    }

    func testQualityReport() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STRETCH_QUALITY"] == "1", "set STRETCH_QUALITY=1 to print the table")
        let source = try Self.speech()
        let source10k = SpeechIntelligibility.resample(source, from: Self.sampleRate)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stretch-quality-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("speech.wav")
        try Self.write(source, to: input)

        let spectral = TimePitchUnit.Algorithm.spectral
        let ipto = TimePitchUnit.Algorithm(subtype: kAudioUnitSubType_AUiPodTimeOther)
        func nutp(_ parameters: [AudioUnitParameterID: AudioUnitParameterValue]) -> TimePitchUnit.Algorithm {
            TimePitchUnit.Algorithm(subtype: kAudioUnitSubType_NewTimePitch, parameters: parameters)
        }
        let candidates: [(String, TimePitchUnit.Algorithm)] = [
            ("nutp default (smoothness 8, coherence on, transients on)", spectral),
            ("nutp smoothness 3", nutp([kNewTimePitchParam_Smoothness: 3])),
            ("nutp smoothness 4", nutp([kNewTimePitchParam_Smoothness: 4])),
            ("nutp smoothness 16", nutp([kNewTimePitchParam_Smoothness: 16])),
            ("nutp smoothness 32", nutp([kNewTimePitchParam_Smoothness: 32])),
            ("nutp coherence off", nutp([kNewTimePitchParam_EnableSpectralCoherence: 0])),
            ("nutp transients off", nutp([kNewTimePitchParam_EnableTransientPreservation: 0])),
            ("nutp transients off, smoothness 4", nutp([kNewTimePitchParam_EnableTransientPreservation: 0, kNewTimePitchParam_Smoothness: 4])),
            ("nutp transients off, smoothness 16", nutp([kNewTimePitchParam_EnableTransientPreservation: 0, kNewTimePitchParam_Smoothness: 16])),
            ("ipto", ipto),
        ]
        var lines = ["| stretch | rate | STOI vs source | STOI vs Rubber Band | over -1 dBFS | peak dBFS | length |", "|---|---|---|---|---|---|---|"]
        for rate in Self.rates {
            let rubberband = try Self.external("rubberband", ["-q", "-3", "-T", "\(rate)", input.path, "%@"], in: directory)
            let atempo = try Self.external("ffmpeg", ["-y", "-loglevel", "error", "-i", input.path, "-af", "atempo=\(rate)", "%@"], in: directory)
            let rubberband10k = rubberband.map { SpeechIntelligibility.resample($0, from: Self.sampleRate) }
            var rows: [(String, [Float])] = candidates.map { ($0.0, Self.stretched(source, rate: rate, algorithm: $0.1)) }
            rows.append(("ipto in 512-frame blocks, outside TimeStretch", Self.blockRendered(source, rate: rate, algorithm: ipto)))
            if let rubberband { rows.append(("Rubber Band R3", rubberband)) }
            if let atempo { rows.append(("ffmpeg atempo", atempo)) }
            for (name, output) in rows {
                let output10k = SpeechIntelligibility.resample(output, from: Self.sampleRate)
                let againstSource = SpeechIntelligibility.score(reference: source10k, processed: output10k, rate: rate)
                let againstRubberband = rubberband10k.map { SpeechIntelligibility.score(reference: $0, processed: output10k) }
                let peak = 20 * log10(Double(output.map(abs).max() ?? 0))
                lines.append(String(format: "| %@ | %.2f | %.4f | %@ | %d | %.2f | %.4f |", name, rate, againstSource,
                                    againstRubberband.map { String(format: "%.4f", $0) } ?? "-",
                                    Self.overCeiling(output), peak, Double(output.count) * rate / Double(source.count)))
            }
        }
        print(lines.joined(separator: "\n"))
    }

    private static func write(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    /// Runs a host tool with "%@" standing for its output WAV, nil when the tool is not installed.
    private static func external(_ tool: String, _ arguments: [String], in directory: URL) throws -> [Float]? {
        #if !os(macOS)
        // The test target also builds for the iOS simulator, which has no Process.
        return nil
        #else
        let output = directory.appendingPathComponent("\(tool)-\(UUID().uuidString).wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + arguments.map { $0 == "%@" ? output.path : $0 }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "")
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let file = try AVAudioFile(forReading: output, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        #endif
    }
}
