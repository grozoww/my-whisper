import Foundation

/// One dictation, after the fact.
///
/// Both the raw transcript and the final text are kept. When cleanup gets something wrong, the
/// only way to tell whether the speech model or the refinement stage is at fault is to see both —
/// and without that, "it typed the wrong thing" is unfixable.
struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var date: Date = Date()

    /// Straight from the speech model.
    var rawText: String
    /// What was actually pasted.
    var finalText: String

    var appName: String?
    var appBundleID: String?
    var modeName: String?
    var providerID: TranscriptionProviderID
    var language: SpeechLanguage
    var usedModel: Bool

    var audioDuration: TimeInterval
    var processingTime: TimeInterval

    /// File name inside `AppDirectories.recordings`, when the user asked to keep audio. A name
    /// rather than a URL, because the containing directory moves with the home directory and an
    /// absolute path baked into JSON would break the day someone migrates their Mac.
    var audioFileName: String?

    var wordCount: Int {
        finalText.split(whereSeparator: { $0.isWhitespace }).count
    }

    var realtimeFactor: Double {
        processingTime > 0 ? audioDuration / processingTime : 0
    }
}

/// See `LenientDecoding.swift`. Losing the whole history file to one added field would be the
/// most destructive version of this bug, since transcripts cannot be regenerated.
extension HistoryEntry {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.value(.id, or: UUID())
        date = container.value(.date, or: Date())
        rawText = container.value(.rawText, or: "")
        finalText = container.value(.finalText, or: "")
        appName = container.optional(.appName)
        appBundleID = container.optional(.appBundleID)
        modeName = container.optional(.modeName)
        providerID = container.value(.providerID, or: .parakeet)
        language = container.value(.language, or: .auto)
        usedModel = container.value(.usedModel, or: false)
        audioDuration = container.value(.audioDuration, or: 0)
        processingTime = container.value(.processingTime, or: 0)
        audioFileName = container.optional(.audioFileName)
    }
}

/// How long transcripts are kept before they delete themselves.
enum HistoryRetention: String, Codable, CaseIterable, Identifiable, Sendable {
    case days7
    case days30
    case days90
    case forever

    var id: String { rawValue }

    var title: String {
        switch self {
        case .days7: "7 days"
        case .days30: "30 days"
        case .days90: "90 days"
        case .forever: "Keep forever"
        }
    }

    var days: Int? {
        switch self {
        case .days7: 7
        case .days30: 30
        case .days90: 90
        case .forever: nil
        }
    }

    /// The cutoff, or `nil` when nothing expires.
    func cutoff(from now: Date = Date()) -> Date? {
        guard let days else { return nil }
        return now.addingTimeInterval(-Double(days) * 86_400)
    }
}
