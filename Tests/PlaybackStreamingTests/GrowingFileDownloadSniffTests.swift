import Foundation
import Testing

@testable import PlaybackStreaming

/// The body sniff for a host that names no audio type: every container the FFmpeg build can
/// demux is taken, a page is not.
extension GrowingFileDownloadTests {

    private static let containers: [(name: String, head: [UInt8])] = [
        ("MP3 frame sync", [0xFF, 0xFB, 0x90, 0x00] + [UInt8](repeating: 0, count: 8)),
        ("MP3 after zero padding", [0, 0, 0, 0, 0xFF, 0xFB, 0x90, 0x00] + [UInt8](repeating: 0, count: 4)),
        ("MP3 behind a longer zero padding", [UInt8](repeating: 0, count: 12)),
        ("ID3 tag", Array("ID3".utf8) + [UInt8](repeating: 0, count: 9)),
        ("ADTS", [0xFF, 0xF1, 0x50, 0x80] + [UInt8](repeating: 0, count: 8)),
        ("LOAS", [0x56, 0xE0, 0x20, 0x00] + [UInt8](repeating: 0, count: 8)),
        ("MP4", [0, 0, 0, 0x20] + Array("ftypM4A ".utf8)),
        ("QuickTime moov-first", [0, 0, 0, 0x08] + Array("moov".utf8) + [UInt8](repeating: 0, count: 4)),
        ("QuickTime mdat-first", [0, 0, 0, 0x08] + Array("mdat".utf8) + [UInt8](repeating: 0, count: 4)),
        ("QuickTime udta-first", [0, 0, 0, 0x08] + Array("udta".utf8) + [UInt8](repeating: 0, count: 4)),
        ("QuickTime ediw-first", [0, 0, 0, 0x08] + Array("ediw".utf8) + [UInt8](repeating: 0, count: 4)),
        ("QuickTime junk-first", [0, 0, 0, 0x08] + Array("junk".utf8) + [UInt8](repeating: 0, count: 4)),
        ("QuickTime pict-first", [0, 0, 0, 0x08] + Array("pict".utf8) + [UInt8](repeating: 0, count: 4)),
        ("QuickTime uuid-first", [0, 0, 0, 0x18] + Array("uuid".utf8) + [UInt8](repeating: 0, count: 4)),
        ("QuickTime prfl-first", [0, 0, 0, 0x08] + Array("prfl".utf8) + [UInt8](repeating: 0, count: 4)),
        ("Ogg", Array("OggS".utf8) + [UInt8](repeating: 0, count: 8)),
        ("FLAC", Array("fLaC".utf8) + [UInt8](repeating: 0, count: 8)),
        ("WAV", Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8)),
        ("Big-endian WAV", Array("RIFX".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8)),
        ("RF64", Array("RF64".utf8) + [0xFF, 0xFF, 0xFF, 0xFF] + Array("WAVE".utf8)),
        ("BW64", Array("BW64".utf8) + [0xFF, 0xFF, 0xFF, 0xFF] + Array("WAVE".utf8)),
        ("AIFF", Array("FORM".utf8) + [0, 0, 0, 0] + Array("AIFF".utf8)),
        ("AIFC", Array("FORM".utf8) + [0, 0, 0, 0] + Array("AIFC".utf8)),
        ("Matroska", [0x1A, 0x45, 0xDF, 0xA3] + [UInt8](repeating: 0, count: 8)),
        ("Monkey's Audio", Array("MAC ".utf8) + [UInt8](repeating: 0, count: 8)),
        ("WavPack", Array("wvpk".utf8) + [UInt8](repeating: 0, count: 8)),
        ("DSF", Array("DSD ".utf8) + [UInt8](repeating: 0, count: 8)),
        ("DSDIFF", Array("FRM8".utf8) + [UInt8](repeating: 0, count: 8)),
        ("ASF", [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11] + [UInt8](repeating: 0, count: 4)),
    ]

    @Test("a body of any enabled container is taken when served as application/octet-stream")
    func everyContainerSniffsAsMedia() {
        for container in Self.containers {
            let h = Harness()
            _ = h.read()
            #expect(h.respond(200, length: 100_000, mimeType: "application/octet-stream"), "\(container.name)")
            h.body(12, head: container.head)
            guard case .serve = h.read() else {
                Issue.record("\(container.name) was refused")
                continue
            }
        }
    }

    private static let notAudio: [(name: String, head: [UInt8])] = [
        ("page", Array("<!DOCTYPE ht".utf8)),
        ("page after zero padding", [0, 0] + Array("<!DOCTYPE ".utf8)),
        ("RIFF AVI", Array("RIFF".utf8) + [0, 0, 0, 0] + Array("AVI ".utf8)),
        ("RIFF WebP", Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBP".utf8)),
    ]

    @Test("a body no enabled demuxer takes is refused when served as application/octet-stream")
    func aPageDoesNotSniffAsMedia() {
        for body in Self.notAudio {
            let h = Harness()
            _ = h.read()
            #expect(h.respond(200, length: 100_000, mimeType: "application/octet-stream"), "\(body.name)")
            h.body(12, head: body.head)
            guard case .fail = h.read() else {
                Issue.record("\(body.name) was taken")
                continue
            }
        }
    }

    @Test("the sniff list names exactly the demuxers scripts/build-ffmpeg.sh enables")
    func sniffListMatchesTheDemuxerList() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/build-ffmpeg.sh")
        let line = try String(contentsOf: script, encoding: .utf8).split(separator: "\n")
            .first { $0.hasPrefix("DEMUXERS=") }
        let enabled = try #require(line).dropFirst("DEMUXERS=".count).split(separator: ",").map(String.init)
        #expect(Set(GrowingFileDownload.sniffers.map(\.demuxer)) == Set(enabled))
    }
}
