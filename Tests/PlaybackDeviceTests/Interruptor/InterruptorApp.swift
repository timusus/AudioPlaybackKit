import AVFoundation
import CallKit
import os
import SwiftUI

/// Another app that takes the audio session from the device tests, then reopens them.
/// `playbackinterruptor://call` reports and answers a CallKit call and ends it after 3 s, so iOS's
/// own call path interrupts; `playbackinterruptor://play` plays a tone for 2 s on a non-mixable
/// `.playback` session and stops without `notifyOthersOnDeactivation`, as a music app does.
@main
struct InterruptorApp: App {
    @State private var running = false

    var body: some Scene {
        WindowGroup {
            Text(running ? "Interrupting" : "Waiting for a URL").onOpenURL { url in
                guard !running else { return }
                running = true
                Task {
                    if url.host == "call" { await Caller().run() } else { await playTone() }
                    running = false
                    await UIApplication.shared.open(URL(string: "playbackdevicetests://back")!)
                }
            }
        }
    }
}

private let log = Logger(subsystem: "com.simplecityapps.playbackdevicetests.interruptor", category: "interruptor")

@MainActor
private func playTone() async {
    let session = AVAudioSession.sharedInstance()
    let engine = AVAudioEngine()
    let rate = 48000.0
    var phase = 0.0
    let tone = AVAudioSourceNode(format: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!) { _, _, frames, buffers in
        let out = UnsafeMutableAudioBufferListPointer(buffers)[0].mData!.assumingMemoryBound(to: Float.self)
        for i in 0..<Int(frames) {
            out[i] = 0.2 * Float(sin(phase))
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
        try await Task.sleep(for: .seconds(2))
    } catch {
        log.error("play failed: \(error)")
    }
    engine.stop()
    try? session.setActive(false)
}

private final class Caller: NSObject, CXProviderDelegate {
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
        update.remoteHandle = CXHandle(type: .generic, value: "Playback device test")
        update.hasVideo = false
        do {
            try await provider.reportNewIncomingCall(with: id, update: update)
            try await controller.request(CXTransaction(action: CXAnswerCallAction(call: id)))
            try await Task.sleep(for: .seconds(3))
            try await controller.request(CXTransaction(action: CXEndCallAction(call: id)))
            // The system deactivates the call's session a moment after the end.
            try await Task.sleep(for: .seconds(1))
        } catch {
            log.error("call failed: \(error)")
        }
        provider.invalidate()
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
