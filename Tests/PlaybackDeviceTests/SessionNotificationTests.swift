import AVFoundation
import MediaPlayer
import XCTest
@testable import PlaybackPlayer

/// The checklist's interruption, route and media-services rows, with the session's notifications
/// posted as iOS posts them; `RealCallTests` proves a real call delivers them.
final class SessionNotificationTests: DeviceTestCase {
    // MARK: Interruptions

    func testInterruptionEndingWithShouldResumeResumes() async {
        await rig.startPlaying()
        SystemSession.interruptionBegan()
        await rig.waitUntil("suppressed") { rig.player.suppression == .interruption }
        XCTAssertTrue(rig.player.playWhenReady)
        await rig.settle()
        XCTAssertEqual(rig.shownState, .paused, "the lock screen shows play while suppressed")
        await rig.assertSilent()

        SystemSession.interruptionEnded(shouldResume: true)
        await rig.waitUntil("resumed") { rig.player.isPlaying }
        XCTAssertEqual(rig.player.suppression, .none)
        await rig.assertAudible()
        await rig.settle()
        XCTAssertEqual(rig.shownState, .playing)
    }

    func testInterruptionEndingWithoutShouldResumeLandsPaused() async {
        await rig.startPlaying()
        SystemSession.interruptionBegan()
        await rig.waitUntil("suppressed") { rig.player.suppression == .interruption }

        SystemSession.interruptionEnded(shouldResume: false)
        await rig.waitUntil("paused by the player") { !rig.player.playWhenReady }
        XCTAssertEqual(rig.player.suppression, .none)
        await rig.waitUntil("interruptionEnded event") {
            rig.didSend { if case .playWhenReadyChanged(false, .interruptionEnded) = $0 { true } else { false } }
        }
        await rig.assertSilent(over: 1)
        XCTAssertFalse(rig.player.playWhenReady, "does not restart on its own")
        await rig.settle()
        XCTAssertEqual(rig.shownState, .paused)
    }

    func testPauseDuringInterruptionResumesNothing() async {
        await rig.startPlaying()
        SystemSession.interruptionBegan()
        await rig.waitUntil("suppressed") { rig.player.suppression == .interruption }
        rig.player.pause()
        XCTAssertEqual(rig.player.suppression, .none)

        SystemSession.interruptionEnded(shouldResume: true)
        await rig.assertSilent(over: 1)
        XCTAssertFalse(rig.player.playWhenReady)
    }

    func testPauseBeforeInterruptionShowsNoSuppressionAndResumesNothing() async {
        await rig.startPlaying()
        rig.player.pause()
        await rig.waitUntil("paused") { !rig.player.isPlaying }

        SystemSession.interruptionBegan()
        await rig.sleep(0.2)
        XCTAssertEqual(rig.player.suppression, .none, "nothing shows paused by another app")
        SystemSession.interruptionEnded(shouldResume: true)
        await rig.assertSilent(over: 1)
        XCTAssertFalse(rig.player.playWhenReady)
        XCTAssertFalse(rig.didSend { if case .playWhenReadyChanged = $0 { true } else { false } })
    }

    func testPlayWhileInterruptedTakesTheSessionBack() async {
        await rig.startPlaying()
        SystemSession.interruptionBegan()
        await rig.waitUntil("suppressed") { rig.player.suppression == .interruption }

        rig.player.play()
        await rig.waitUntil("playing again") { rig.player.isPlaying }
        XCTAssertEqual(rig.player.suppression, .none)
        await rig.assertAudible()
        // The interruption's end, once the call stops ringing, changes nothing.
        SystemSession.interruptionEnded(shouldResume: false)
        await rig.sleep(0.2)
        XCTAssertTrue(rig.player.playWhenReady)
        await rig.assertAudible(over: 0.5)
    }

    // MARK: Routes

    func testLosingHeadphonesPausesAndNothingStartsWhenTheyReturn() async {
        await rig.startPlaying()
        SystemSession.routeChanged(.oldDeviceUnavailable, previous: [.headphones])
        await rig.waitUntil("paused by the route loss") { !rig.player.playWhenReady }
        await rig.waitUntil("routeLost event") {
            rig.didSend { if case .playWhenReadyChanged(false, .routeLost) = $0 { true } else { false } }
        }
        await rig.assertSilent()

        SystemSession.routeChanged(.newDeviceAvailable, previous: [.builtInSpeaker])
        await rig.assertSilent(over: 1)
        XCTAssertFalse(rig.player.playWhenReady, "nothing starts by itself")
    }

    /// The rule a Bluetooth loss takes; whether iOS sends it for real needs the earbuds.
    func testLosingBluetoothPauses() async {
        await rig.startPlaying()
        SystemSession.routeChanged(.oldDeviceUnavailable, previous: [.bluetoothA2DP])
        await rig.waitUntil("paused by the route loss") { !rig.player.playWhenReady }
        await rig.assertSilent()
    }

    func testCategoryChangeAndNewDeviceDoNotPause() async {
        await rig.startPlaying()
        SystemSession.routeChanged(.categoryChange, previous: [.headphones])
        SystemSession.routeChanged(.newDeviceAvailable, previous: [.builtInSpeaker])
        await rig.sleep(0.2)
        XCTAssertTrue(rig.player.playWhenReady)
        await rig.assertAudible()
    }

    func testRouteLossDuringInterruptionResumesNothing() async {
        await rig.startPlaying()
        SystemSession.interruptionBegan()
        await rig.waitUntil("suppressed") { rig.player.suppression == .interruption }
        SystemSession.routeChanged(.oldDeviceUnavailable, previous: [.headphones])
        await rig.waitUntil("paused by the route loss") { !rig.player.playWhenReady }

        SystemSession.interruptionEnded(shouldResume: true)
        await rig.assertSilent(over: 1)
        XCTAssertFalse(rig.player.playWhenReady, "nothing resumes onto the speaker")
    }

    // MARK: Media-services reset

    func testResetLandsPausedAtThePositionAndPlayResumesFromIt() async {
        await rig.startPlaying(at: 2, position: 3)
        await rig.sleep(0.5)
        await resetAndAssertRecovered(index: 2)

        let kept = rig.player.position
        rig.player.play()
        await rig.waitUntil("playing after the reset") { rig.player.isPlaying && rig.player.position > kept + 0.1 }
        XCTAssertEqual(rig.player.currentIndex, 2, "the same item")
        XCTAssertLessThan(rig.player.position, kept + 1, "resumes from where it paused")
        await rig.assertAudible()
    }

    func testTwoResetsWithAPlayBetweenEachLandPaused() async {
        await rig.startPlaying(at: 2)
        await resetAndAssertRecovered(index: 2)
        rig.player.play()
        await rig.waitUntil("playing after the first reset") { rig.player.isPlaying }
        await rig.assertAudible(over: 0.5)

        await resetAndAssertRecovered(index: 2)
        rig.player.play()
        await rig.waitUntil("playing after the second reset") { rig.player.isPlaying }
        await rig.assertAudible(over: 0.5)
    }

    func testResetDuringInterruptionLandsPausedAndPlayWorks() async {
        await rig.startPlaying(at: 2)
        SystemSession.interruptionBegan()
        await rig.waitUntil("suppressed") { rig.player.suppression == .interruption }
        await resetAndAssertRecovered(index: 2)

        SystemSession.interruptionEnded(shouldResume: true)
        await rig.assertSilent(over: 0.5)
        XCTAssertFalse(rig.player.playWhenReady, "the reset ended the interruption")
        rig.player.play()
        await rig.waitUntil("playing after the reset") { rig.player.isPlaying }
        await rig.assertAudible()
    }

    /// Posts the reset and checks the player rebuilt its output and stopped where it was heard.
    private func resetAndAssertRecovered(index: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let before = rig.player.position
        let recoveries = rig.events.count { if case .recoveredPaused = $0 { true } else { false } }
        SystemSession.mediaServicesWereReset()
        await rig.waitUntil("recoveredPaused", file: file, line: line) {
            rig.events.count { if case .recoveredPaused = $0 { true } else { false } } > recoveries
        }
        XCTAssertFalse(rig.player.playWhenReady, file: file, line: line)
        XCTAssertEqual(rig.player.suppression, .none, file: file, line: line)
        XCTAssertEqual(rig.player.currentIndex, index, file: file, line: line)
        XCTAssertEqual(rig.player.position, before, accuracy: 1, "paused at the same position", file: file, line: line)
        await rig.settle()
        XCTAssertEqual(rig.shownState, .paused, "the lock screen shows paused", file: file, line: line)
        await rig.assertSilent(file: file, line: line)
    }
}
