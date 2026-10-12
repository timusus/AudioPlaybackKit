import Foundation
import XCTest
@testable import PlaybackNowPlaying

/// The lock screen's elapsed time, extrapolated as the system does from the last published elapsed
/// and rate, against `player.position`, over a few seconds of real playback after each step.
final class ElapsedTimeTests: DeviceTestCase {
    func testSeekInTheApp() async {
        await rig.startPlaying(at: 2)
        rig.player.seek(to: 4)
        await rig.waitUntil("seek heard") { rig.didSend { if case .seekLanded = $0 { true } else { false } } }
        await assertElapsedInStep(over: 4.5)
    }

    func testSeekOnTheLockScreen() async {
        await rig.startPlaying(at: 2)
        rig.send(.changePlaybackPosition, .position(4))
        await rig.waitUntil("seek heard") { rig.didSend { if case .seekLanded = $0 { true } else { false } } }
        XCTAssertEqual(rig.player.position, 4, accuracy: 0.25, "the app's position jumps with it")
        await assertElapsedInStep(over: 4.5)
    }

    func testPauseThenPlay() async {
        await rig.startPlaying(at: 2)
        rig.player.pause()
        await rig.waitUntil("paused") { !rig.player.isPlaying }
        await assertElapsedInStep(over: 2)
        rig.player.play()
        await rig.waitUntil("playing") { rig.player.isPlaying }
        await assertElapsedInStep(over: 3)
    }

    func testRateUpAndBack() async {
        await rig.startPlaying(at: 2)
        rig.player.rate = 1.5
        await assertElapsedInStep(over: 2.5)
        rig.player.rate = 1
        await assertElapsedInStep(over: 2.5)
    }

    func testSeekWhilePaused() async {
        await rig.startPlaying(at: 2)
        rig.player.pause()
        await rig.waitUntil("paused") { !rig.player.isPlaying }
        rig.player.seek(to: 5)
        await rig.settle()
        XCTAssertEqual(rig.shownElapsed ?? -1, 5, accuracy: 0.01, "elapsed shows the new position while paused")
        XCTAssertEqual(rig.shownRate, 0)
        await assertElapsedInStep(over: 1)
        rig.player.play()
        await rig.waitUntil("playing") { rig.player.isPlaying }
        await assertElapsedInStep(over: 3)
    }

    func testGaplessJoin() async {
        await rig.startPlaying(at: 0, position: 2.5)
        let start = (clock: rig.output.currentTime(), wall: Date())
        await assertElapsedInStep(over: 4)
        XCTAssertEqual(rig.player.currentIndex, 1)
        XCTAssertTrue(rig.didSend { if case .itemTransition(0, 1, .auto) = $0 { true } else { false } })
        XCTAssertEqual(rig.shownTitle, Fixture.items[1])
        XCTAssertEqual(rig.shownDuration ?? 0, 8, accuracy: 0.05)
        // No gap: the output clock kept wall time across the join.
        let advanced = rig.output.currentTime() - start.clock
        // 0.15 s: the clock's own jitter, as in `assertAudible`.
        XCTAssertEqual(advanced, Date().timeIntervalSince(start.wall), accuracy: 0.15)
    }

    /// Every 50 ms for `seconds`, the shown elapsed plus rate times the time since it was written
    /// matches the player's position within 0.25 s, and the shown title its item.
    ///
    /// While the heard position still stands where elapsed was last written at a running rate, the
    /// output is starting and the system extrapolates ahead; the session rewrites elapsed once it moves.
    /// That wait is bounded on its own: on an iPhone the clock started up to 0.36 s after a seek or a
    /// fresh renderer's play, then the position held one output latency more (0.15 s on Bluetooth).
    private func assertElapsedInStep(over seconds: TimeInterval, file: StaticString = #filePath, line: UInt = #line) async {
        var worst = 0.0
        var longestStart = 0.0
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            // The session publishes from a task after each player change, so it is run first rather than raced.
            await rig.settle()
            guard let elapsed = rig.shownElapsed, let rate = rig.shownRate else {
                return XCTFail("nothing published", file: file, line: line)
            }
            let sinceWrite = Date().timeIntervalSince(rig.infoCenter.lastWrite)
            if rate > 0, abs(rig.player.position - elapsed) < 0.001 {
                longestStart = max(longestStart, sinceWrite)
            } else {
                worst = max(worst, abs(elapsed + rate * sinceWrite - rig.player.position))
            }
            XCTAssertEqual(rig.shownTitle, rig.player.currentItem, file: file, line: line)
            try? await Task.sleep(for: .milliseconds(50))
        }
        // 0.25 = the transport's 100 ms position report plus the 0.15 s Bluetooth output latency.
        XCTAssertLessThan(worst, 0.25, "largest gap between extrapolated elapsed and position", file: file, line: line)
        XCTAssertLessThan(longestStart, 0.6, "output start before the position moved", file: file, line: line)
    }
}
