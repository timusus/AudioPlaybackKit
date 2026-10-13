import PlaybackDecode
import PlaybackPlayer
import PlaybackPlayerTestSupport
import PlaybackRender
import XCTest

final class PlayAFileRecipe: XCTestCase {
    // PCM only: decode a file yourself and hand the chunks to your own renderer.
    func testDecodeAFileToPCM() throws {
        let url = try writeWAV(seconds: 3)
        let decoder = FFmpegStreamDecoder(reader: try FileByteReader(url: url))
        let format = try decoder.open()

        var frames = 0
        while let chunk = decoder.nextChunk() {
            frames += chunk.count / format.channelCount
        }

        XCTAssertEqual(format.sampleRate, 8000)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(frames, 3 * 8000)
        // A nil chunk is only the end of the file when `endReason` says so.
        XCTAssertEqual(decoder.endReason, .eof)
    }

    // The whole stack: `Player` over a file. `PlayerTestRig` swaps the speaker and clock for fakes,
    // so the test plays three seconds in no time; an app passes only `makeSource`.
    @MainActor
    func testPlayAFileWithPlayer() throws {
        let url = try writeWAV(seconds: 3)
        let rig = PlayerTestRig<URL> { FFmpegItemSource(reader: try FileByteReader(url: $0)) }
        let player = rig.player!

        player.setItems([url])
        player.play()
        rig.run(for: 1)

        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.duration ?? 0, 3, accuracy: 0.01)
        XCTAssertEqual(player.position, 1, accuracy: 0.3)

        rig.run(for: 3)
        XCTAssertEqual(player.state, .ended)
    }
}
