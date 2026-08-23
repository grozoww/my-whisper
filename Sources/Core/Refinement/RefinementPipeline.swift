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

    /// `clipboard` is what the user had copied when they started speaking, or nil when nothing
    /// read it. Whether the model is shown it at all is the mode's decision, made here so there is
    /// one place to look for the answer to "why did the model see my clipboard". Pasting it is a
    /// different toggle and happens after this, in `DictationController` — the model is never
    /// shown the text it is about to paste verbatim.
    func refine(
        _ raw: String,
        mode: Mode,
        settings: RefinementSettings,
        vocabulary: [VocabularyEntry],
        language: SpeechLanguage,
        clipboard: String? = nil
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
            context: mode.usesClipboardContext ? clipboard.map(ClipboardContext.reference) : nil,
            clipboardPlaceholder: placeholderToPlace(mode: mode, clipboard: clipboard, spoken: cleaned),
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

    /// The placeholder to ask the model to mark, or nil to not ask at all.
    ///
    /// Every condition here has to hold before the request goes in the prompt, and the last one is
    /// the important one: the model is asked *where* the clipboard goes, never *whether* it was
    /// asked for. Without that check a model that decided the sentence would read better with
    /// something dropped into it would drop the clipboard mid-thought, and the end of the text —
    /// where it lands with no placeholder at all — is the safer place to be wrong.
    private func placeholderToPlace(mode: Mode, clipboard: String?, spoken: String) -> String? {
        guard mode.pastesClipboard, let clipboard, !clipboard.isEmpty else { return nil }

        let placeholder = mode.clipboardPlaceholder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ClipboardContext.mentioned(placeholder, in: spoken) else { return nil }
        return placeholder
    }
}

private extension CleanupOptions {
    func applyingVocabularyOnly() -> CleanupOptions {
        var options = self
        options.applyVocabulary = true
        return options
    }
}
