import AVFoundation
import UIKit
import XCTest
@testable import PlaybackPlayer

/// The checklist's call rows with iOS's own interruptions: the Interruptor app, installed beside the
/// host by `scripts/device-test.sh`, takes the session and reopens the host when it is done.
final class RealCallTests: DeviceTestCase {
    private var received: [Notification] = []
    private var observer: NSObjectProtocol?

    override func setUp() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("the simulator has no CallKit calls")
        #else
        // xcodebuild passes TEST_RUNNER_DEVICE_INTERRUPTOR through without its prefix.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DEVICE_INTERRUPTOR"] == "1", "needs the Interruptor app; run scripts/device-test.sh")
        try await super.setUp()
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.received.append(note) }
        }
        #endif
    }

    override func tearDown() async throws {
        observer.map(NotificationCenter.default.removeObserver)
        try await super.tearDown()
    }

    func testCallInterruptsAndPlaybackResumesWhenItEnds() async {
        await rig.startPlaying(at: 2)
        await interrupt(with: "call")
        await rig.waitUntil("suppressed by the call", timeout: 15) { rig.player.suppression == .interruption }
        XCTAssertTrue(rig.player.playWhenReady)
        await rig.assertSilent()

        await rig.waitUntil("resumed after the call", timeout: 20) { rig.player.isPlaying }
        XCTAssertEqual(rig.player.suppression, .unsuppressed)
        let ended = received.last { type(of: $0) == .ended }
        XCTAssertTrue(ended.map(shouldResume) ?? false, "iOS ends a call's interruption with shouldResume")
        XCTAssertTrue(received.allSatisfy { $0.object as AnyObject? === AVAudioSession.sharedInstance() })
        await waitForHost()
        await rig.assertAudible()
    }

    /// A music app taking the session never ends the interruption with shouldResume, so playback
    /// stays stopped until the listener plays again.
    func testNonMixablePlaybackInterruptsAndNothingResumes() async {
        await rig.startPlaying(at: 2)
        await interrupt(with: "play")
        await rig.waitUntil("suppressed by the other app", timeout: 15) { rig.player.suppression == .interruption }
        await waitForHost()
        await rig.assertSilent(over: 1)
        XCTAssertFalse(received.contains { type(of: $0) == .ended && shouldResume($0) })

        rig.player.play()
        await rig.waitUntil("playing again") { rig.player.isPlaying }
        await rig.assertAudible()
    }

    private func interrupt(with host: String, file: StaticString = #filePath, line: UInt = #line) async {
        let opened = await UIApplication.shared.open(URL(string: "playbackinterruptor://\(host)")!)
        XCTAssertTrue(opened, "the Interruptor app is installed", file: file, line: line)
    }

    /// The Interruptor reopens the host once its call or tone is over.
    private func waitForHost(file: StaticString = #filePath, line: UInt = #line) async {
        await rig.waitUntil("the host back in front", timeout: 20, file: file, line: line) {
            UIApplication.shared.applicationState == .active
        }
    }

    private func type(of note: Notification) -> AVAudioSession.InterruptionType? {
        (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
    }

    private func shouldResume(_ note: Notification) -> Bool {
        let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        return AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
    }
}
