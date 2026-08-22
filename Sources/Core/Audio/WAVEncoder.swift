import Foundation

/// Packs 16 kHz mono float samples into a WAV file in memory.
///
/// Cloud providers take a file, not an array of floats, and going through `AVAudioFile` would mean
/// writing the user's voice to disk on every dictation just to read it straight back. This keeps
/// it in memory: nothing to clean up, nothing left behind if the app crashes mid-upload.
///
/// Samples are written as 16-bit PCM. That halves the upload against 32-bit float for no accuracy
/// the speech models can use — they quantise to this depth anyway.
enum WAVEncoder {
    static func encode(samples: [Float], sampleRate: Double = AudioCapture.targetSampleRate) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = UInt32(sampleRate) * UInt32(blockAlign)
        let dataBytes = UInt32(samples.count * Int(blockAlign))

        var data = Data(capacity: 44 + Int(dataBytes))

        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))

        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))       // PCM header length
        data.appendLittleEndian(UInt16(1))        // format 1 == uncompressed PCM
        data.appendLittleEndian(channels)
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)

        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(dataBytes)

        for sample in samples {
            // Clamp before scaling. A sample slightly outside -1...1 — which conversion and gain
            // can both produce — would otherwise wrap around and turn a loud syllable into a click.
            let clamped = max(-1, min(1, sample))
            let value = Int16(clamped * Float(Int16.max))
            data.appendLittleEndian(UInt16(bitPattern: value))
        }

        return data
    }
}

private extension Data {
    /// WAV is a little-endian format, so every multi-byte field is written low byte first
    /// regardless of what the machine does natively.
    mutating func appendLittleEndian(_ value: UInt16) {
        let little = value.littleEndian
        append(UInt8(truncatingIfNeeded: little))
        append(UInt8(truncatingIfNeeded: little >> 8))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        let little = value.littleEndian
        append(UInt8(truncatingIfNeeded: little))
        append(UInt8(truncatingIfNeeded: little >> 8))
        append(UInt8(truncatingIfNeeded: little >> 16))
        append(UInt8(truncatingIfNeeded: little >> 24))
    }
}
