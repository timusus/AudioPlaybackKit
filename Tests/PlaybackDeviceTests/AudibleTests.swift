import XCTest

/// "Playing" means heard: the renderer runs, its clock keeps wall time at the rate, and real audio
/// reaches it. "Paused" means its clock stands still.
final class AudibleTests: DeviceTestCase {
    func testPlayIsHeardAndPauseIsSilent() async {
        await rig.startPlaying()
        await rig.assertAudible()

        rig.player.pause()
        await rig.waitUntil("paused") { !rig.player.isPlaying }
        await rig.assertSilent()

        rig.player.play()
        await rig.waitUntil("playing again") { rig.player.isPlaying }
        await rig.assertAudible()
    }

    func testFasterRateIsHeardAtThatRate() async {
        await rig.startPlaying(at: 2)
        rig.player.rate = 1.5
        await rig.settle()
        await rig.assertAudible()
    }
}
