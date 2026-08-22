import AVFoundation
import Foundation
import OSLog

/// Runs a WAV file through the transcription provider and logs the result.
///
/// Exists because the interactive path cannot be exercised without Accessibility permission,
/// which a fresh checkout, a CI runner, and an automated agent all lack. This gives every one of
/// them a way to answer the only question that matters — does the model actually transcribe on
/// this machine — with one command:
///
///     OURWHISPER_SELFTEST=/path/to/speech.wav open -a OurWhisper
///
/// Set `OURWHISPER_SELFTEST_LANGUAGE` to a code such as `ru` to pin the language.
enum SelfTest {
    private static let log = Logger(subsystem: "com.grozoww.ourwhisper", category: "selftest")

    static var requestedPath: String? {
        ProcessInfo.processInfo.environment["OURWHISPER_SELFTEST"]
    }

    static var requestedLanguage: SpeechLanguage {
        guard let raw = ProcessInfo.processInfo.environment["OURWHISPER_SELFTEST_LANGUAGE"],
              let language = SpeechLanguage(rawValue: raw)
        else { return .auto }
        return language
    }

    static func run(path: String, language: SpeechLanguage, provider: any TranscriptionProvider) async {
        log.info("Self-test starting: \(path, privacy: .public) [\(language.rawValue, privacy: .public)]")

        do {
            let samples = try loadSamples(at: path)
            let seconds = Double(samples.count) / AudioCapture.targetSampleRate
            log.info("Loaded \(samples.count) samples (\(seconds, format: .fixed(precision: 2))s)")

            try await provider.prepare(progress: nil)

            let result = try await provider.transcribe(samples: samples, language: language)
            log.info("RESULT: \(result.text, privacy: .public)")
            log.info(
                "TIMING: audio \(result.audioDuration, format: .fixed(precision: 2))s, processing \(result.processingTime, format: .fixed(precision: 2))s, \(result.realtimeFactor, format: .fixed(precision: 1))x realtime, confidence \(result.confidence, format: .fixed(precision: 2))"
            )
            log.info("Self-test finished")
        } catch {
            log.error("SELFTEST FAILED: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reads any audio file AVFoundation understands and converts it to the 16 kHz mono float
    /// the models expect — the same target `AudioCapture` produces, so the self-test exercises
    /// the real input format rather than a convenient one.
    private static func loadSamples(at path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCapture.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCapture.CaptureError.converterUnavailable
        }

        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw AudioCapture.CaptureError.converterUnavailable
        }

        let ratio = target.sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(file.length) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity),
              let input = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
              )
        else {
            throw AudioCapture.CaptureError.converterUnavailable
        }

        try file.read(into: input)

        try converter.convertOnce(input, into: output)

        guard let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
