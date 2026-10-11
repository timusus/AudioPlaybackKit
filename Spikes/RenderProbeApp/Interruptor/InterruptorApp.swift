import AVFoundation
import CallKit
import SwiftUI

/// Check A10's other app: a non-mixable .playback session interrupts the probe, plays 3 s of 440 Hz,
/// gives the session back with .notifyOthersOnDeactivation and reopens the probe.
/// With `--call` (check A11) it instead reports an incoming CallKit call, answers it, holds it 5 s, ends it
/// and reopens the probe, so the system's call path does the interrupting.
@main
struct InterruptorApp: App {
    private static let calling = CommandLine.arguments.contains("--call")

    var body: some Scene {
        WindowGroup {
            Text(Self.calling ? "Calling for 5 s" : "Interrupting for 3 s").task {
                if Self.calling { await Caller().run() } else { await interrupt() }
                await UIApplication.shared.open(URL(string: "renderprobe://back")!)
            }
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
    }
}

final class Caller: NSObject, CXProviderDelegate {
    private let provider = CXProvider(configuration: {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.supportedHandleTypes = [.generic]
        configuration.maximumCallGroups = 1
        return configuration
    }())
    private let controller = CXCallController()
    private let id = UUID()

    func run() async {
        provider.setDelegate(self, queue: nil)
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "Render Probe check")
        update.hasVideo = false
        do {
            try await provider.reportNewIncomingCall(with: id, update: update)
            try await controller.request(CXTransaction(action: CXAnswerCallAction(call: id)))
            try await Task.sleep(nanoseconds: 5_000_000_000)
            try await controller.request(CXTransaction(action: CXEndCallAction(call: id)))
            // The system deactivates the call's session a moment after the end.
            try await Task.sleep(nanoseconds: 1_000_000_000)
        } catch {
            print("caller: \(error)")
        }
    }

    func providerDidReset(_ provider: CXProvider) {}

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // CallKit expects the session set up for a call before it activates it.
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [])
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
    }
}
