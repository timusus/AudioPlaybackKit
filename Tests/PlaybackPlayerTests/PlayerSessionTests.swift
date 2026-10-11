import Foundation
import PlaybackRender
import XCTest
@testable import PlaybackPlayer

private struct SessionError: Error {}

/// The `AVAudioSession` rules of ADR-0019, driven through `FakeAudioSession`. media3's audio focus
/// maps onto them: a transient loss is an interruption, a permanent loss is an interruption that ends
/// without `shouldResume`, and becoming noisy is `oldDeviceUnavailable`.
@MainActor
final class PlayerSessionTests: XCTestCase {
    private var rig: PlayerRig!
    private var player: Player<String> { rig.player }
    private var session: FakeAudioSession { rig.session }

    override func setUp() async throws {
        rig = PlayerRig()
    }

    /// Plays `items` for a second, so the session is active and the output running.
    private func startPlaying(_ items: [String] = ["a", "b"]) {
        player.setItems(items)
        player.play()
        rig.run(for: 1)
        XCTAssertTrue(player.isPlaying)
    }

    /// Whether audio is being heard: the output clock runs and the position moves with it.
    private func isHeard() -> Bool {
        let before = player.position
        rig.run(for: 1)
        return rig.output.rate > 0 && player.position > before
    }

    // media3 AudioFocusManagerTest.setAudioAttributes_withUsageMedia_usesAudioFocusGain,
    // updateAudioFocus_idleToBuffering_setsPlayerCommandPlayWhenReady,
    // updateAudioFocus_pausedToPlaying_setsPlayerCommandPlayWhenReady and
    // updateAudioFocus_toPausedWithFocus_setsPlayerCommandPlayWhenReady.
    func testTheFirstPlayActivatesOnceBeforeTheTransportPlays() {
        XCTAssertEqual(session.calls, [.configure], "the category is set at init")
        session.holdsActivation = true
        player.setItems(["a", "b"])
        player.play()
        XCTAssertEqual(session.calls, [.configure, .activate])
        XCTAssertFalse(isHeard(), "the transport waits for the session")

        session.completeActivation()
        XCTAssertTrue(isHeard())

        player.pause()
        player.play()
        XCTAssertTrue(isHeard())
        XCTAssertEqual(session.calls, [.configure, .activate], "a pause keeps the session active")
    }

    // media3 AudioFocusManagerTest.updateAudioFocus_toPausedBeforeRequestingFocus_setsPlayerCommandPlayWhenReady
    // and updateAudioFocus_readyToIdle_withoutFocus_isNoOp.
    func testPauseAndStopBeforeAnyPlayLeaveTheSessionAlone() {
        player.setItems(["a"])
        player.pause()
        player.stop()
        player.removeAll()
        XCTAssertEqual(session.calls, [.configure])
    }

    func testAThrowingActivationRefusesThePlayWithASessionError() async {
        session.activationError = SessionError()
        player.setItems(["a", "b"])
        player.play()
        XCTAssertEqual(player.error?.kind, .session)
        XCTAssertEqual(player.state, .idle)
        XCTAssertTrue(player.playWhenReady, "the user's next tap retries")
        XCTAssertFalse(isHeard())
        XCTAssertEqual(session.calls, [.configure, .activate], "never active, so nothing to deactivate")

        session.activationError = nil
        player.play()
        XCTAssertNil(player.error)
        XCTAssertTrue(isHeard())
        XCTAssertEqual(session.activations, 2)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.failedIndices(events), [], "the item did not fail")
    }

    // media3 AudioFocusManagerTest.onAudioFocusChange_withTransientLoss_sendsCommandWaitForCallback.
    func testInterruptionBeganSuppressesAndPausesTheTransport() {
        startPlaying()
        session.interruptionBegan()
        XCTAssertEqual(player.suppression, .interruption)
        XCTAssertTrue(player.playWhenReady)
        XCTAssertEqual(player.state, .ready)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(isHeard())
    }

    func testInterruptionEndedWithShouldResumeReactivatesAndPlays() async {
        startPlaying()
        session.interruptionBegan()
        rig.run(for: 1)
        session.interruptionEnded(shouldResume: true)
        XCTAssertEqual(player.suppression, .none)
        XCTAssertTrue(player.playWhenReady)
        XCTAssertTrue(isHeard())
        XCTAssertEqual(session.activations, 2)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.playWhenReadyChanges(events), [])
    }

    // media3 AudioFocusManagerTest.updateAudioFocus_toPausedWithFocusLoss_setsPlayerCommandDoNotPlay and
    // onAudioFocusChange_withFocusLoss_sendsDoNotPlayAndAbandonsFocus: a loss that does not come back.
    func testInterruptionEndedWithoutShouldResumeSetsPlayWhenReadyFalse() async {
        startPlaying()
        session.interruptionBegan()
        session.interruptionEnded(shouldResume: false)
        XCTAssertEqual(player.suppression, .none)
        XCTAssertFalse(player.playWhenReady)
        XCTAssertFalse(isHeard())
        XCTAssertEqual(session.activations, 1)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.playWhenReadyChanges(events), [.init(value: false, reason: .interruptionEnded)])
    }

    func testAnAppPauseDuringAnInterruptionPreventsTheResume() async {
        startPlaying()
        session.interruptionBegan()
        player.pause()
        XCTAssertEqual(player.suppression, .none, "nothing suppresses what the app paused")
        session.interruptionEnded(shouldResume: true)
        XCTAssertFalse(player.playWhenReady)
        XCTAssertFalse(isHeard())
        XCTAssertEqual(session.activations, 1)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.playWhenReadyChanges(events), [], "the app paused, not the player")
    }

    // media3 AudioFocusManagerTest.updateAudioFocus_toPausedWithTransientFocusLoss_setsPlayerCommandWaitForCallback:
    // paused when the loss came, nothing resumes when it goes.
    func testAnInterruptionWhilePausedNeitherSuppressesNorResumes() {
        startPlaying()
        player.pause()
        session.interruptionBegan()
        XCTAssertEqual(player.suppression, .none)
        session.interruptionEnded(shouldResume: true)
        XCTAssertFalse(player.playWhenReady)
        XCTAssertFalse(isHeard())

        player.play()
        XCTAssertTrue(isHeard())
        XCTAssertEqual(session.activations, 2, "the interruption deactivated the session")
    }

    func testAReactivationThatThrowsStaysSuppressedUntilTheNextPlay() {
        startPlaying()
        session.interruptionBegan()
        session.activationError = SessionError()
        session.interruptionEnded(shouldResume: true)
        XCTAssertEqual(player.suppression, .interruption)
        XCTAssertTrue(player.playWhenReady)
        XCTAssertNil(player.error)
        XCTAssertFalse(isHeard())

        session.activationError = nil
        player.play()
        XCTAssertEqual(player.suppression, .none)
        XCTAssertTrue(isHeard())
    }

    // media3 AudioFocusManagerTest.updateAudioFocus_pausedToPlayingWithTransientLossAndRegularGain_setsPlayerCommandPlayWhenReady:
    // the app asks to play during the interruption, and the session takes it back.
    func testAPlayDuringAnInterruptionReactivatesAndPlays() {
        startPlaying()
        session.interruptionBegan()
        player.play()
        XCTAssertEqual(player.suppression, .none)
        XCTAssertTrue(isHeard())
        session.interruptionEnded(shouldResume: false)
        XCTAssertTrue(player.playWhenReady, "an interruption already given up changes nothing")
        XCTAssertTrue(isHeard())
    }

    // media3 AudioFocusManagerTest.updateAudioFocus_pausedToPlayingWithTransientLossAndNoGain_setsPlayerCommandDoNotPlay.
    func testAPlayDuringAnInterruptionThatCannotActivateStaysSuppressed() {
        startPlaying()
        session.interruptionBegan()
        session.activationError = SessionError()
        player.play()
        XCTAssertEqual(player.suppression, .interruption)
        XCTAssertFalse(isHeard())

        session.activationError = nil
        session.interruptionEnded(shouldResume: true)
        XCTAssertTrue(isHeard())
    }

    func testASeekAndASkipDuringAnInterruptionAreAppliedPaused() async {
        startPlaying(["a", "b", "c"])
        session.interruptionBegan()
        player.seek(to: 5)
        XCTAssertFalse(isHeard())
        XCTAssertEqual(player.position, 5)
        player.skipToNext()
        player.seek(to: 3, itemAt: 2)
        XCTAssertFalse(isHeard())
        XCTAssertEqual(player.currentIndex, 2)

        session.interruptionEnded(shouldResume: true)
        XCTAssertTrue(isHeard())
        XCTAssertEqual(player.currentIndex, 2)
        XCTAssertGreaterThan(player.position, 3)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.transitions(events), [
            .init(from: 0, to: 1, reason: .seek), .init(from: 1, to: 2, reason: .seek),
        ])
    }

    // media3 ExoPlayerTest.pausesWhenBecomingNoisyIfBecomingNoisyHandlingIsEnabled.
    func testHeadphonesUnpluggedPausesWithRouteLost() async {
        startPlaying()
        session.routeChanged(reason: .oldDeviceUnavailable, previous: [.headphones], current: [.builtIn])
        XCTAssertFalse(player.playWhenReady)
        XCTAssertFalse(isHeard())
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.playWhenReadyChanges(events), [.init(value: false, reason: .routeLost)])
    }

    func testRouteChangesThatLoseNoPersonalOutputPlayOn() async {
        startPlaying()
        // A2DP to HFP: the Bluetooth device is still there.
        session.routeChanged(reason: .oldDeviceUnavailable, previous: [.bluetooth], current: [.bluetooth])
        // A speaker-only route going, as when a call ends.
        session.routeChanged(reason: .oldDeviceUnavailable, previous: [.builtIn, .other], current: [.builtIn])
        // Plugging in is the app's preference to act on, not the player's.
        session.routeChanged(reason: .newDeviceAvailable, previous: [.builtIn], current: [.headphones])
        session.routeChanged(reason: .other, previous: [.headphones], current: [.builtIn])
        XCTAssertTrue(player.playWhenReady)
        XCTAssertTrue(isHeard())
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.playWhenReadyChanges(events), [])
    }

    func testAnUnplugDuringAnInterruptionCancelsTheResume() async {
        startPlaying()
        session.interruptionBegan()
        session.routeChanged(reason: .oldDeviceUnavailable, previous: [.carAudio], current: [.builtIn])
        XCTAssertFalse(player.playWhenReady)
        session.interruptionEnded(shouldResume: true)
        XCTAssertFalse(player.playWhenReady)
        XCTAssertFalse(isHeard(), "never resumes onto the speaker")
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.playWhenReadyChanges(events), [.init(value: false, reason: .routeLost)])
    }

    /// The output and the session each hear a reset; either may be first.
    private func reset(outputFirst: Bool) {
        if outputFirst { rig.output.injectReset() }
        session.mediaServicesReset()
        if !outputFirst { rig.output.injectReset() }
        rig.pump()
    }

    func testAMediaServicesResetReconfiguresLandsPausedAndSendsRecoveredPaused() async {
        startPlaying()
        rig.run(for: 1)
        let heard = player.position
        reset(outputFirst: false)
        XCTAssertEqual(rig.output.rebuilds, 1, "the transport rebuilt the output")
        XCTAssertFalse(player.playWhenReady)
        XCTAssertEqual(player.state, .ready)
        XCTAssertEqual(player.position, heard, accuracy: 0.25)
        XCTAssertFalse(isHeard())
        XCTAssertEqual(session.calls, [.configure, .activate, .configure])

        player.play()
        XCTAssertTrue(isHeard())
        XCTAssertEqual(session.calls, [.configure, .activate, .configure, .activate])
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.kinds(events), [.recoveredPaused])
    }

    func testTwoResetsInARowEachRecoverPaused() async {
        startPlaying()
        reset(outputFirst: true)
        reset(outputFirst: false)
        XCTAssertEqual(rig.output.rebuilds, 2)
        XCTAssertFalse(player.playWhenReady)
        XCTAssertNil(player.error)
        XCTAssertFalse(isHeard())
        XCTAssertEqual(session.configurations, 3)

        player.play()
        XCTAssertTrue(isHeard())
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.kinds(events), [.recoveredPaused, .recoveredPaused])
    }

    func testAResetDuringAnInterruptionLandsPausedAndNeverResumes() async {
        startPlaying()
        session.interruptionBegan()
        reset(outputFirst: false)
        XCTAssertEqual(player.suppression, .none)
        XCTAssertFalse(player.playWhenReady)
        session.interruptionEnded(shouldResume: true)
        XCTAssertFalse(player.playWhenReady)
        XCTAssertFalse(isHeard())
        XCTAssertEqual(session.activations, 1)
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.kinds(events), [.recoveredPaused])
    }

    func testARendererFailureTheTransportRecoversLandsPausedAndSendsRecoveredPaused() async {
        startPlaying()
        rig.output.injectFailure()
        rig.pump()
        XCTAssertEqual(rig.output.rebuilds, 1)
        XCTAssertFalse(player.playWhenReady, "the UI shows paused, not playing over silence")
        XCTAssertEqual(player.state, .ready)
        XCTAssertNil(player.error)
        XCTAssertFalse(isHeard())

        player.play()
        XCTAssertTrue(isHeard())
        XCTAssertEqual(session.calls, [.configure, .activate], "the session was never lost")
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.kinds(events), [.recoveredPaused])
    }

    // The seek's answer would drop events held before it, but the recovery's pause outlives the seek.
    func testARecoveryHeldBehindASeekStillLandsPaused() async {
        startPlaying()
        let recovery = rig.inFlight {
            rig.output.injectFailure()
            rig.timer.fire()
        }
        let answer = rig.inFlight { player.seek(to: 0.5) }
        rig.deliver(recovery)
        rig.deliver(answer)
        XCTAssertFalse(player.playWhenReady)
        XCTAssertFalse(isHeard())
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.kinds(events).filter { $0 == .recoveredPaused }.count, 1)
    }

    // A play the transport took after its recovery, before the player heard of it, is paused with it,
    // so the intent and the transport agree.
    func testAPlayRacingARecoveryEndsPausedWithTheTransport() {
        startPlaying()
        player.pause()
        let recovery = rig.inFlight {
            rig.output.injectFailure()
            rig.timer.fire()
        }
        player.play()
        rig.deliver(recovery)
        XCTAssertFalse(player.playWhenReady)
        XCTAssertFalse(isHeard())
    }

    // With nothing loaded there is nothing to suppress, so nothing resumes onto an empty session.
    func testAnInterruptionAfterStopThatShouldResumeLeavesTheSessionInactive() async {
        startPlaying()
        player.stop()
        session.interruptionBegan()
        XCTAssertEqual(player.suppression, .none)
        session.interruptionEnded(shouldResume: true)
        XCTAssertEqual(session.calls, [.configure, .activate, .deactivate])
        XCTAssertEqual(player.state, .idle)

        player.play()
        XCTAssertTrue(isHeard())
        XCTAssertEqual(session.calls, [.configure, .activate, .deactivate, .activate])
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.playWhenReadyChanges(events), [])
    }

    func testAnInterruptionAfterStopThatEndsForGoodSendsNothing() async {
        startPlaying()
        player.stop()
        session.interruptionBegan()
        session.interruptionEnded(shouldResume: false)
        XCTAssertEqual(player.suppression, .none)
        XCTAssertTrue(player.playWhenReady, "stop keeps the intent, as media3 does")
        XCTAssertEqual(session.calls, [.configure, .activate, .deactivate])
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.playWhenReadyChanges(events), [], "the user already stopped it")
    }

    // media3 AudioFocusManagerTest.updateAudioFocus_readyToIdle_abandonsAudioFocus.
    func testStopDeactivatesAndTheNextPlayActivatesAgain() {
        startPlaying()
        player.stop()
        XCTAssertEqual(session.calls, [.configure, .activate, .deactivate])
        player.play()
        XCTAssertTrue(isHeard())
        XCTAssertEqual(session.calls, [.configure, .activate, .deactivate, .activate])
    }

    func testEmptyingTheListDeactivates() {
        startPlaying()
        player.remove(at: 1)
        XCTAssertEqual(session.deactivations, 0)
        player.remove(at: 0)
        XCTAssertEqual(session.deactivations, 1)
        player.setItems([])
        XCTAssertEqual(session.deactivations, 1, "already inactive")
    }

    // media3 AudioFocusManagerTest.updateAudioFocus_readyToIdle_abandonsAudioFocus: an error is idle too.
    func testAPlayOntoAnItemThatFailsToMakeNeverActivates() {
        rig.factory.failing = ["a"]
        player.setItems(["a"])
        player.play()
        XCTAssertEqual(player.error?.kind, .source)
        XCTAssertEqual(session.calls, [.configure])

        rig.factory.failing = []
        player.play()
        XCTAssertTrue(isHeard())
        XCTAssertEqual(session.calls, [.configure, .activate])
    }

    func testACurrentItemFailingDeactivatesAndTheNextPlayActivatesAgain() {
        rig.factory.failingAtFrame = ["a": 40]
        startPlaying()
        rig.run(for: 5)
        XCTAssertEqual(player.error?.kind, .source)
        XCTAssertEqual(session.calls, [.configure, .activate, .deactivate])

        rig.factory.failingAtFrame = [:]
        player.play()
        XCTAssertTrue(isHeard())
        XCTAssertEqual(session.calls, [.configure, .activate, .deactivate, .activate])
    }

    func testReachingAFailedNextDeactivates() {
        rig.factory.failing = ["b"]
        startPlaying()
        rig.run(for: 10)
        XCTAssertEqual(player.currentItem, "b")
        XCTAssertEqual(player.error?.kind, .source)
        XCTAssertEqual(session.calls, [.configure, .activate, .deactivate])
    }

    func testAFailureWhileActivatingDeactivatesAndIgnoresTheLateAnswer() {
        rig.factory.failing = ["b"]
        session.holdsActivation = true
        player.setItems(["a", "b"])
        player.play()
        player.skipToNext()
        session.completeActivation()
        XCTAssertFalse(isHeard())
        XCTAssertEqual(session.calls, [.configure, .activate, .deactivate])
    }

    // Failed, nothing is left to resume, as when the interruption began after the failure.
    func testAFailureDuringAnInterruptionResumesNothing() async {
        rig.factory.failing = ["c"]
        startPlaying(["a", "b", "c"])
        session.interruptionBegan()
        player.seek(to: 0, itemAt: 2)
        XCTAssertEqual(player.error?.kind, .source)
        XCTAssertEqual(player.suppression, .none)
        session.interruptionEnded(shouldResume: true)
        XCTAssertEqual(session.calls, [.configure, .activate], "the system already deactivated it")
        let events = await rig.finish()
        XCTAssertEqual(PlayerRig.playWhenReadyChanges(events), [])
    }

    func testAStopWhileActivatingIgnoresTheLateAnswer() {
        session.holdsActivation = true
        player.setItems(["a"])
        player.play()
        player.stop()
        session.completeActivation()
        XCTAssertFalse(isHeard())
        XCTAssertEqual(session.calls, [.configure, .activate, .deactivate])
    }
}
