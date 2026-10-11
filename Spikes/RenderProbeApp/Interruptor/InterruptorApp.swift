import AVFoundation
import SwiftUI

/// Check A10's other app: a non-mixable .playback session interrupts the probe, plays 3 s of 440 Hz,
/// gives the session back with .notifyOthersOnDeactivation and reopens the probe.
@main
struct InterruptorApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Interrupting for 3 s").task { await interrupt() }
        }
    }

    @MainActor
    private func interrupt() async {
        let session = AVAudioSession.sharedInstance()
        let engine = AVAudioEngine()
        let rate = 48000.0
        var phase = 0.0
        let tone = AVAudioSourceNode(format: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!) { _, _, frames, buffers in
            let out = UnsafeMutableAudioBufferListPointer(buffers)[0].mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<Int(frames) {
                out[i] = 0.3 * Float(sin(phase))
                phase += 2 * .pi * 440 / rate
            }
            return noErr
        }
        engine.attach(tone)
        engine.connect(tone, to: engine.mainMixerNode, format: nil)
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            try engine.start()
            try await Task.sleep(nanoseconds: 3_000_000_000)
        } catch {
            print("interruptor: \(error)")
        }
        engine.stop()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        await UIApplication.shared.open(URL(string: "renderprobe://back")!)
    }
}
