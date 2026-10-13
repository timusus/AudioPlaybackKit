/// Decoder bugs found by the APE/WavPack/DSD/WMA fixtures (#171), pinned like `KnownIssues.rules`.
/// Not fixed here: the issue link is the tracking issue for the batch until each gets its own.
extension KnownIssues {
    private static let unknownLength: [FaultSwitches] = [
        .unknownLength, [.partialReads, .unknownLength], [.ioErrorOncePerPosition, .unknownLength],
        [.partialReads, .ioErrorOncePerPosition, .unknownLength],
    ]
    private static let ioError: [FaultSwitches] = [.ioErrorOncePerPosition, [.partialReads, .ioErrorOncePerPosition]]
    private static let ioErrorUnknownLength: [FaultSwitches] = [
        [.ioErrorOncePerPosition, .unknownLength], [.partialReads, .ioErrorOncePerPosition, .unknownLength],
    ]

    private static let wavpack = "https://github.com/timusus/AudioPlaybackKit/issues/175 (WavPack, FFmpeg's wv demuxer: with no length it cannot find the APE tag after the last block and fails on it)"
    private static let wma = "https://github.com/timusus/AudioPlaybackKit/issues/171 (WMA: resume after an I/O error repeats frames; unknown-length seeks land early)"

    private static func wv(_ kind: ConformanceMatrix.Kind, _ switches: [FaultSwitches], _ message: String) -> Rule {
        Rule(issue: wavpack, fixture: "wavpack_stereo.wv", kind: kind, switches: switches, messages: [message])
    }

    private static func wmaRule(_ kind: ConformanceMatrix.Kind, _ switches: [FaultSwitches], _ message: String) -> Rule {
        Rule(issue: wma, fixture: "wma_v2_stereo.wma", kind: kind, switches: switches, messages: [message])
    }

    static let codecRules: [Rule] = [
        wv(.outcome, unknownLength, "outcome decoded(end: \"failure\"), clean decoded(end: \"eof\")"),
        wv(.seek, unknownLength, "seek to 4.0 threw streaming decode failed: malformed: the demuxer could not read a packet averror=-1094995529"),
        wv(.seek, unknownLength, "seek count 4 vs 5"),
        wmaRule(.resumePCM, ioError, "PCM differs from the clean decode at sample 205814 (180220 vs 176128 frames, resumes at frames [98299, 169961])"),
        wmaRule(.frameCount, ioError, "180220 frames, clean 176128"),
        wmaRule(.resumePCM, ioErrorUnknownLength, "PCM differs from the clean decode at sample 205814 (180219 vs 176128 frames, resumes at frames [98299])"),
        wmaRule(.frameCount, ioErrorUnknownLength, "180219 frames, clean 176128"),
        wmaRule(.seekLanding, ioError, "seek to 1.3312773998488283s landed 1.331s, clean 1.3312773998488283s"),
        wmaRule(.seekPCM, ioError, "seek to 1.3312773998488283s: PCM after the landing differs from the clean seek"),
        wmaRule(.seekPCM, unknownLength, "seek to 1.3312773998488283s: PCM after the landing at 1.331s sits -4082 frames off, clean seek 12971"),
    ]
}
