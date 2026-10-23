import AVFoundation
import Foundation
import PlaybackDecode
import PlaybackPlayer
import PlaybackRender

/// The timed states `scripts/device-energy.sh` records. Each boundary is one line, `energy <epoch-ms> <state>`,
/// appended to Documents/energy.log, so the script can cut the trace by state without a shared clock.
@MainActor
enum EnergyScenario {
    static let stateSeconds = 60.0
    static var isRequested: Bool { ProcessInfo.processInfo.environment["PLAYBACK_ENERGY"] == "1" }

    static func run() async {
        let log = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("energy.log")
        var lines = ""
        func mark(_ state: String) {
            let line = "energy \(Int(Date().timeIntervalSince1970 * 1000)) \(state)\n"
            print(line, terminator: "")
            lines += line
            try? lines.write(to: log, atomically: true, encoding: .utf8)
        }
        // codehealth-ignore tests-swift-sleep: a measurement, not an assertion; each state must last real time for the profiler
        func hold() async { try? await Task.sleep(for: .seconds(stateSeconds)) }

        let url = Bundle.main.url(forResource: "cbr_info_64k.mp3", withExtension: nil)!
        let player = Player<Int>(makeSource: { _ in try FFmpegItemSource(reader: FileByteReader(url: url)) })
        // The 8 s fixture loops, so every state has audio to decode.
        player.repeatMode = .one
        player.setItems([0])
        player.play()
        mark("start")
        mark("playing-1x")
        await hold()
        player.rate = 1.5
        mark("playing-1.5x")
        await hold()
        player.rate = 1
        player.pause()
        mark("paused")
        await hold()
        player.stop()
        mark("idle")
        await hold()

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback)
        try? session.setActive(true)
        let baseline = try? AVAudioPlayer(contentsOf: url)
        baseline?.numberOfLoops = -1
        baseline?.play()
        mark("avaudioplayer")
        await hold()
        baseline?.stop()
        mark("done")
    }
}
