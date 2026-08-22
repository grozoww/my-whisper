import Foundation
import OSLog

/// Turns a raw transcript into the text that actually gets pasted.
///
/// Two stages, in this order and never the other way round: rules first, model second. Rules are
/// free and certain, so they run even when the model will run too — and if the model is off,
/// unavailable, slow, or produces nonsense, what is already in hand is a cleaned transcript rather
/// than a raw one.
@MainActor
final class RefinementPipeline {
    struct Result: Sendable {
        var text: String
        /// True when the on-device model contributed. Surfaced in History so a surprising result
        /// can be traced to the stage that produced it.
        var usedModel: Bool
    }

    private let log = Logger(subsystem: "com.grozoww.ourwhisper", category: "refine")
    private let onDevice: OnDeviceRefiner

    init(onDevice: OnDeviceRefiner) {
        self.onDevice = onDevice
    }

    func refine(
        _ raw: String,
        mode: Mode,
        settings: RefinementSettings,
        vocabulary: [VocabularyEntry],
        language: SpeechLanguage
    ) async -> Result {
        guard settings.isEnabled else { return Result(text: raw, usedModel: false) }

        let rules = RuleRefiner(options: mode.cleanup, vocabulary: vocabulary, language: language)
        let cleaned = rules.refine(raw)

        guard settings.useOnDeviceModel, onDevice.availability.isAvailable, !mode.instructions.isEmpty else {
            return Result(text: cleaned, usedModel: false)
        }

        let refined = await onDevice.refine(
            cleaned,
            instructions: mode.instructions,
            timeout: .seconds(max(1, settings.modelTimeoutSeconds))
        )

        guard let refined else { return Result(text: cleaned, usedModel: false) }

        // Vocabulary is re-applied after the model. A rewrite can undo a substitution by restating
        // the name in the model's preferred spelling, and the vocabulary list is the user telling
        // us, explicitly, which spelling wins.
        let final = mode.cleanup.applyVocabulary
            ? RuleRefiner(
                options: CleanupOptions.none.applyingVocabularyOnly(),
                vocabulary: vocabulary,
                language: language
            ).refine(refined)
            : refined

        log.debug("Refined with the on-device model")
        return Result(text: final, usedModel: true)
    }
}

private extension CleanupOptions {
    func applyingVocabularyOnly() -> CleanupOptions {
        var options = self
        options.applyVocabulary = true
        return options
    }
}
