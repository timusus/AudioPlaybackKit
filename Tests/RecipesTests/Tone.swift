import Foundation

/// A mono 16-bit WAV of a sine, so a recipe plays a real file without a bundled fixture.
enum Tone {
    static let sampleRate = 8000

    static func wav(seconds: Int, hz: Double = 440, amplitude: Double = 0.5) -> Data {
        let frames = seconds * sampleRate
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + frames * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16))
        put(UInt16(1)); put(UInt16(1)); put(UInt32(sampleRate)); put(UInt32(sampleRate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(frames * 2))
        for frame in 0..<frames {
            put(Int16(amplitude * 32767 * sin(2 * .pi * hz * Double(frame) / Double(sampleRate))))
        }
        return data
    }

    static func writeWAV(seconds: Int, named name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).wav")
        try wav(seconds: seconds).write(to: url)
        return url
    }
}
