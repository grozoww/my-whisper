import Foundation

/// Languages the app offers in the UI.
///
/// `isLocal` is the important bit: Parakeet TDT v3 covers 25 European languages, so anything
/// outside that set needs the cloud provider. The UI uses this to explain *why* a language wants
/// an API key, instead of silently producing nonsense.
enum SpeechLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto
    case english = "en"
    case russian = "ru"
    case ukrainian = "uk"
    case spanish = "es"
    case german = "de"
    case french = "fr"
    case polish = "pl"
    case chinese = "zh"
    case japanese = "ja"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Detect automatically"
        case .english: "English"
        case .russian: "Русский"
        case .ukrainian: "Українська"
        case .spanish: "Español"
        case .german: "Deutsch"
        case .french: "Français"
        case .polish: "Polski"
        case .chinese: "中文"
        case .japanese: "日本語"
        }
    }

    /// Whether the offline engine can handle this language.
    var isLocal: Bool {
        !Self.cloudOnly.contains(self)
    }

    /// Parakeet v3 is European-only. These two need Soniox.
    static let cloudOnly: Set<SpeechLanguage> = [.chinese, .japanese]

    /// BCP-47 hints passed to cloud providers. `auto` sends nothing and lets the model decide.
    var hints: [String] {
        self == .auto ? [] : [rawValue]
    }
}
