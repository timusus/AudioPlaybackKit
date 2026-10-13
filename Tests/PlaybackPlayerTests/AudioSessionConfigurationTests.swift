#if os(iOS)
import AVFoundation
import XCTest
@testable import PlaybackPlayer

private struct CategoryError: Error {}

private final class RecordingSession: CategorySetting {
    var applied: [(AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.RouteSharingPolicy, AVAudioSession.CategoryOptions)] = []
    var error: (any Error)?

    func setCategory(
        _ category: AVAudioSession.Category,
        mode: AVAudioSession.Mode,
        policy: AVAudioSession.RouteSharingPolicy,
        options: AVAudioSession.CategoryOptions
    ) throws {
        if let error { throw error }
        applied.append((category, mode, policy, options))
    }
}

/// AirPlay 2 buffered playback needs `.longFormAudio` set together with `.playback`.
final class AudioSessionConfigurationTests: XCTestCase {
    func testTheMusicPresetSetsPlaybackWithLongFormRouteSharingAndNoOptions() throws {
        let session = RecordingSession()
        try AudioSessionConfiguration.longFormAudio.apply(to: session)
        XCTAssertEqual(session.applied.count, 1)
        XCTAssertEqual(session.applied[0].0, .playback)
        XCTAssertEqual(session.applied[0].1, .default)
        XCTAssertEqual(session.applied[0].2, .longFormAudio)
        // Mixing and ducking options do not belong with long-form route sharing, so the preset has none.
        XCTAssertTrue(session.applied[0].3.isEmpty)
    }

    func testTheSpeechPresetKeepsLongFormRouteSharing() throws {
        let session = RecordingSession()
        try AudioSessionConfiguration.spokenAudio.apply(to: session)
        XCTAssertEqual(session.applied[0].1, .spokenAudio)
        XCTAssertEqual(session.applied[0].2, .longFormAudio)
    }

    func testAFailureToSetTheCategoryIsThrownToTheCaller() {
        let session = RecordingSession()
        session.error = CategoryError()
        XCTAssertThrowsError(try AudioSessionConfiguration.longFormAudio.apply(to: session)) {
            XCTAssertTrue($0 is CategoryError)
        }
    }
}
#endif
