import Foundation
import OSLog

/// Picks which engine transcribes a given utterance, and explains itself when it cannot.
///
/// The routing rule the rest of the app relies on: **audio never leaves the machine implicitly**.
/// Choosing a language Parakeet cannot handle does not quietly start uploading. It fails with a
/// message naming the switch the user has to turn on, and only then does the cloud engine run.
@MainActor
@Observable
final class TranscriptionRouter {
    private let log = Logger(subsystem: "com.grozoww.ourwhisper", category: "router")

    let parakeet: ParakeetProvider
    private(set) var soniox: SonioxProvider

    /// The Soniox model the current `soniox` instance was built with, so a settings change is
    /// noticed without rebuilding the actor on every dictation.
    private var sonioxModel: String

    init(parakeet: ParakeetProvider = ParakeetProvider(), sonioxModel: String = "stt-async-preview") {
        self.parakeet = parakeet
        self.sonioxModel = sonioxModel
        self.soniox = SonioxProvider(model: sonioxModel)
    }

    enum RoutingError: LocalizedError {
        case cloudNeededButDisabled(SpeechLanguage)
        case cloudNeededButNoKey(SpeechLanguage)
        case noKey

        var errorDescription: String? {
            switch self {
            case .cloudNeededButDisabled(let language):
                "\(language.displayName) needs the cloud model. Turn on \"Use the cloud model for languages Parakeet cannot handle\" in Configuration."
            case .cloudNeededButNoKey(let language):
                "\(language.displayName) needs the cloud model, which needs a Soniox API key. Add one in Configuration."
            case .noKey:
                "The cloud model is selected but has no API key. Add one in Configuration."
            }
        }
    }

    /// Resolves the engine for one dictation. Throws rather than silently falling back, so the
    /// pill can say what to do about it.
    func provider(for settings: DictationSettings) throws -> any TranscriptionProvider {
        refreshSonioxIfNeeded(model: settings.sonioxModel)

        let language = settings.language
        let hasKey = KeychainStore.has(.soniox)

        if !language.isLocal {
            guard settings.allowCloudFallback else { throw RoutingError.cloudNeededButDisabled(language) }
            guard hasKey else { throw RoutingError.cloudNeededButNoKey(language) }
            log.info("Routing \(language.rawValue, privacy: .public) to Soniox: Parakeet does not cover it")
            return soniox
        }

        if settings.provider == .soniox {
            guard hasKey else { throw RoutingError.noKey }
            return soniox
        }

        return parakeet
    }

    /// Which engine `provider(for:)` would return, for display. Never throws — the UI wants to
    /// show the intent even when it is currently unusable.
    func plannedProviderID(for settings: DictationSettings) -> TranscriptionProviderID {
        if !settings.language.isLocal { return .soniox }
        return settings.provider
    }

    private func refreshSonioxIfNeeded(model: String) {
        guard model != sonioxModel else { return }
        sonioxModel = model
        soniox = SonioxProvider(model: model)
        log.info("Soniox model changed to \(model, privacy: .public)")
    }
}
