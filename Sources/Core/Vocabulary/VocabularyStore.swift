import Foundation
import Observation

/// A word the speech model keeps getting wrong, and what it should be.
///
/// Names, product names and jargon are where a general-purpose model is weakest, and no amount of
/// prompt engineering fixes "Kruhlov" coming back as "Kruglov". A substitution list does, exactly,
/// every time — which is why this runs as a rule and not as a hint to a model.
struct VocabularyEntry: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    /// The spelling you want.
    var term: String
    /// What the model tends to produce instead. Case-insensitive; matched on word boundaries so
    /// "Ana" cannot rewrite the middle of "banana".
    var soundsLike: [String] = []
    var isEnabled: Bool = true

    /// Every spelling this entry replaces, longest first.
    ///
    /// Longest-first matters: with "AI" and "AI agent" both listed, matching the short one first
    /// would consume the word and leave "AI agent" unreachable.
    var patterns: [String] {
        soundsLike
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
    }
}

/// See `LenientDecoding.swift`.
extension VocabularyEntry {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.value(.id, or: UUID())
        term = container.value(.term, or: "")
        soundsLike = container.value(.soundsLike, or: [])
        isEnabled = container.value(.isEnabled, or: true)
    }
}

@MainActor
@Observable
final class VocabularyStore {
    private(set) var entries: [VocabularyEntry] = []

    @ObservationIgnored private let file: JSONFileStore<[VocabularyEntry]>

    init(directory: URL = AppDirectories.support) {
        file = JSONFileStore(fileName: "vocabulary.json", directory: directory)
        entries = file.load() ?? []
    }

    var enabledEntries: [VocabularyEntry] {
        entries.filter { $0.isEnabled && !$0.term.isEmpty && !$0.patterns.isEmpty }
    }

    @discardableResult
    func add(term: String = "", soundsLike: [String] = []) -> VocabularyEntry {
        let entry = VocabularyEntry(term: term, soundsLike: soundsLike)
        entries.append(entry)
        save()
        return entry
    }

    func update(_ entry: VocabularyEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        save()
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func flush() { file.flush() }

    private func save() { file.save(entries) }
}
