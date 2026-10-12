import Foundation
import PlaybackRender
import XCTest
@_spi(Testing) @testable import PlaybackPlayer

/// `audioFormat`, media3 `getAudioFormat()`, on the fake output: items are ten seconds at 8 Hz mono
/// unless the factory gives them their own format.
@MainActor
final class PlayerAudioFormatTests: XCTestCase {
    private var rig: PlayerRig!
    private var player: Player<String> { rig.player }
    private let mono8 = PCMFormat(sampleRate: 8, channelCount: 1)
    private let stereo16 = PCMFormat(sampleRate: 16, channelCount: 2)

    override func setUp() async throws {
        rig = PlayerRig()
    }

    // #150: Shuttle2's EQ draws its curve at the rate its filters run at.
    func testTheFormatIsTheOneTheProcessorsAreConfiguredWith() {
        let recorder = FormatRecorder()
        rig.factory.formats = ["a": stereo16]
        player.setProcessors([recorder])
        player.setItems(["a"])
        XCTAssertNil(player.audioFormat, "unknown until the item is heard")

        rig.pump()
        XCTAssertEqual(player.audioFormat, stereo16)
        XCTAssertEqual(recorder.inputs.last, stereo16)
    }

    func testTheFormatChangesWhenTheNextItemIsHeard() {
        rig.factory.formats = ["b": stereo16]
        player.setItems(["a", "b"])
        player.play()
        rig.run(for: 9)
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(player.audioFormat, mono8, "b is decoded ahead but not heard")

        rig.run(for: 2)
        XCTAssertEqual(player.currentIndex, 1)
        XCTAssertEqual(player.audioFormat, stereo16)
    }

    // As `duration`, it never describes the item before (#145).
    func testALoadForgetsTheFormatUntilTheNewItemIsHeard() {
        rig.factory.formats = ["b": stereo16]
        player.setItems(["a", "b"])
        rig.pump()
        XCTAssertEqual(player.audioFormat, mono8)

        player.skipToNext()
        XCTAssertNil(player.audioFormat)
        rig.pump()
        XCTAssertEqual(player.audioFormat, stereo16)
    }

    // Set late, the join into b is heard, but the player stays on a (ADR-0023).
    func testPauseAtEndSetLateKeepsTheFinishedItemsFormat() {
        rig.factory.formats = ["b": stereo16]
        player.setItems(["a", "b"])
        player.play()
        rig.run(for: 9)
        player.pauseAtEndOfItem = true
        rig.run(for: 2)
        XCTAssertEqual(player.currentIndex, 0)
        XCTAssertEqual(player.audioFormat, mono8)
    }
}

/// Passes audio through and records each format it is configured with.
private final class FormatRecorder: AudioProcessor, @unchecked Sendable {
    private let lock = NSLock()
    private var configured: [PCMFormat] = []

    var inputs: [PCMFormat] { lock.withLock { configured } }

    func configure(_ input: PCMFormat) throws -> PCMFormat {
        lock.withLock { configured.append(input) }
        return input
    }

    var isActive: Bool { true }
    func process(_ samples: UnsafeMutableBufferPointer<Float>) {}
    func flush(_ metadata: StreamMetadata) {}
    func reset() {}
}
