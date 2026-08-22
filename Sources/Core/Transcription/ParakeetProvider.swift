import FluidAudio
import Foundation
import OSLog

/// Offline transcription with NVIDIA Parakeet TDT v3, running on the Neural Engine through
/// FluidAudio's CoreML runtime.
///
/// Chosen over Whisper on evidence rather than reputation: on FLEURS it scores 3.00% WER on
/// Russian against Whisper large-v3's 4.04%, and 5.10% against 12.52% on Ukrainian, while being
/// roughly 11x faster and a third of the size.
actor ParakeetProvider: TranscriptionProvider {
    nonisolated let id: TranscriptionProviderID = .parakeet
    nonisolated var displayName: String { "Parakeet TDT v3" }

    /// Below this the model has nothing to work with. Roughly a third of a second — shorter than
    /// any real word plus the delay between speaking and releasing the key.
    private static let minimumSamples = Int(AudioCapture.targetSampleRate * 0.3)

    private let log = Logger(subsystem: "com.grozoww.ourwhisper", category: "parakeet")

    private var manager: AsrManager?
    private var loadTask: Task<AsrManager, Error>?

    /// Cached rather than asking the manager each time: `AsrManager.isAvailable` is
    /// actor-isolated, and an async getter cannot satisfy the protocol's requirement.
    private(set) var isReady = false

    func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if manager != nil { return }

        // Two hotkey presses in quick succession must not start two downloads. Whoever arrives
        // first owns the load; everyone else awaits the same task.
        if let loadTask {
            manager = try await loadTask.value
            return
        }

        let task = Task<AsrManager, Error> { [log] in
            log.info("Loading Parakeet TDT v3…")
            let models = try await AsrModels.downloadAndLoad(
                version: .v3,
                progressHandler: { update in progress?(update.fractionCompleted) }
            )
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            log.info("Parakeet ready")
            return manager
        }
        loadTask = task

        do {
            let loaded = try await task.value
            manager = loaded
            isReady = await loaded.isAvailable
        } catch {
            // Clear the task so the next attempt retries instead of awaiting a failure forever.
            loadTask = nil
            throw TranscriptionError.engine(error.localizedDescription)
        }
    }

    func transcribe(samples: [Float], language: SpeechLanguage) async throws -> Transcription {
        guard language.isLocal else {
            throw TranscriptionError.languageNotSupported(language, by: displayName)
        }
        guard samples.count >= Self.minimumSamples else {
            throw TranscriptionError.tooShort
        }
        guard let manager, isReady else {
            throw TranscriptionError.notReady
        }

        do {
            // Fresh decoder state per utterance. The state carries linguistic context across
            // chunks of one recording, which is what we want inside a sentence — and emphatically
            // not what we want between two unrelated dictations minutes apart.
            var decoderState = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)

            let result = try await manager.transcribe(
                samples,
                decoderState: &decoderState,
                language: Self.fluidLanguage(for: language)
            )
            return Transcription(
                text: result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines),
                confidence: result.confidence,
                audioDuration: result.duration,
                processingTime: result.processingTime
            )
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.engine(error.localizedDescription)
        }
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
        loadTask = nil
        isReady = false
    }

    /// Maps our UI language to FluidAudio's. Passing one biases token selection toward that
    /// script, which is what stops a Ukrainian sentence coming back half-transliterated.
    /// `nil` lets the model decide.
    private static func fluidLanguage(for language: SpeechLanguage) -> Language? {
        switch language {
        case .auto: nil
        case .english: .english
        case .russian: .russian
        case .ukrainian: .ukrainian
        case .spanish: .spanish
        case .german: .german
        case .french: .french
        case .polish: .polish
        // Handled by dedicated models, not this one — `isLocal` rejects them above.
        case .chinese, .japanese: nil
        }
    }
}
