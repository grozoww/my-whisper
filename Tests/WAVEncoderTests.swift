import Foundation
import Testing

@testable import OurWhisper

/// The WAV header is what the cloud provider parses before it ever sees a sample. A wrong byte
/// here fails as "the provider rejected your audio", which points at everything except the header.
@Suite("WAV encoding")
struct WAVEncoderTests {
    private func ascii(_ data: Data, at offset: Int, length: Int = 4) -> String {
        String(decoding: data[offset..<(offset + length)], as: UTF8.self)
    }

    private func littleEndian32(_ data: Data, at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(data[data.startIndex + offset + index]) << (8 * UInt32(index))
        }
        return value
    }

    private func littleEndian16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    @Test("The header says RIFF/WAVE/fmt/data in the right places")
    func writesCanonicalHeader() {
        let data = WAVEncoder.encode(samples: [0, 0.5, -0.5])
        #expect(ascii(data, at: 0) == "RIFF")
        #expect(ascii(data, at: 8) == "WAVE")
        #expect(ascii(data, at: 12) == "fmt ")
        #expect(ascii(data, at: 36) == "data")
    }

    @Test("Format fields describe 16 kHz mono 16-bit PCM")
    func describesTheRightFormat() {
        let data = WAVEncoder.encode(samples: [0])
        #expect(littleEndian32(data, at: 16) == 16)      // PCM header length
        #expect(littleEndian16(data, at: 20) == 1)       // uncompressed
        #expect(littleEndian16(data, at: 22) == 1)       // mono
        #expect(littleEndian32(data, at: 24) == 16_000)  // sample rate
        #expect(littleEndian32(data, at: 28) == 32_000)  // byte rate: 16000 * 2
        #expect(littleEndian16(data, at: 32) == 2)       // block align
        #expect(littleEndian16(data, at: 34) == 16)      // bits per sample
    }

    @Test("Declared sizes match the bytes actually written")
    func sizesAreConsistent() {
        let samples = [Float](repeating: 0.25, count: 1_000)
        let data = WAVEncoder.encode(samples: samples)

        #expect(data.count == 44 + samples.count * 2)
        #expect(littleEndian32(data, at: 4) == UInt32(data.count - 8))
        #expect(littleEndian32(data, at: 40) == UInt32(samples.count * 2))
    }

    @Test("Out-of-range samples clamp instead of wrapping")
    func clampsRatherThanWrapping() {
        // Conversion and gain can both push a sample past 1.0. Without the clamp, Int16 overflow
        // turns the loudest moment of a recording into a click at the opposite polarity.
        let data = WAVEncoder.encode(samples: [2.0, -2.0])
        let first = Int16(bitPattern: littleEndian16(data, at: 44))
        let second = Int16(bitPattern: littleEndian16(data, at: 46))

        #expect(first == Int16.max)
        #expect(second == -Int16.max)
    }

    @Test("Silence encodes as zeroes")
    func encodesSilence() {
        let data = WAVEncoder.encode(samples: [0, 0, 0])
        #expect(littleEndian16(data, at: 44) == 0)
        #expect(littleEndian16(data, at: 46) == 0)
    }

    @Test("An empty recording still produces a valid, empty file")
    func handlesEmptyInput() {
        let data = WAVEncoder.encode(samples: [])
        #expect(data.count == 44)
        #expect(littleEndian32(data, at: 40) == 0)
    }
}
