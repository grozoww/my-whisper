import Foundation
import Observation
import OSLog

/// Every dictation, newest first, with a retention setting that is actually enforced.
///
/// Stored as one JSON file rather than a database. A few thousand transcripts is a file measured
/// in megabytes, which loads in milliseconds and — the part that matters for a privacy-first app —
/// can be read, audited and deleted by the user with tools they already have.
@MainActor
@Observable
final class HistoryStore {
    private let log = Logger(subsystem: "com.grozoww.ourwhisper", category: "history")

    private(set) var entries: [HistoryEntry] = []

    @ObservationIgnored private let file: JSONFileStore<[HistoryEntry]>

    /// Above this the file stops being something you can open in a text editor, and the memory
    /// cost stops being free. Retention normally bites long before this does; it is a backstop for
    /// "keep forever" plus heavy use.
    private static let hardLimit = 20_000

    init(directory: URL = AppDirectories.support) {
        file = JSONFileStore(fileName: "history.json", directory: directory)
        entries = file.load() ?? []
    }

    // MARK: - Recording

    func record(_ entry: HistoryEntry, settings: HistorySettings) {
        guard settings.isEnabled else { return }
        entries.insert(entry, at: 0)
        prune(retention: settings.retention)
        save()
    }

    // MARK: - Reading

    /// Case- and diacritic-insensitive search over both texts and the app name. Diacritic
    /// folding is not a nicety here: the app is used in Ukrainian and Russian, where typing the
    /// exact accented form of a word into a search box is a poor thing to require.
    func search(_ query: String) -> [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter { entry in
            entry.finalText.localizedStandardContains(trimmed)
                || entry.rawText.localizedStandardContains(trimmed)
                || (entry.appName?.localizedStandardContains(trimmed) ?? false)
        }
    }

    // MARK: - Statistics

    /// What the Home screen shows. Computed rather than counted incrementally, so it can never
    /// drift out of step with the list it claims to summarise.
    struct Stats: Equatable, Sendable {
        var averageRealtimeFactor: Double = 0
        var totalWords: Int = 0
        var distinctApps: Int = 0
        /// Seconds of typing saved, using `typingWordsPerMinute` below.
        var secondsSaved: Double = 0
    }

    /// 40 wpm: a reasonable sustained rate for composing prose at a keyboard, rather than the
    /// 60–80 quoted for copy-typing existing text. Overstating this would make the headline number
    /// flattering and useless.
    static let typingWordsPerMinute = 40.0

    var stats: Stats {
        guard !entries.isEmpty else { return Stats() }

        let factors = entries.map(\.realtimeFactor).filter { $0 > 0 }
        let words = entries.reduce(0) { $0 + $1.wordCount }
        let apps = Set(entries.compactMap(\.appBundleID)).count

        let typingSeconds = Double(words) / Self.typingWordsPerMinute * 60
        let spokenSeconds = entries.reduce(0) { $0 + $1.audioDuration + $1.processingTime }

        return Stats(
            averageRealtimeFactor: factors.isEmpty ? 0 : factors.reduce(0, +) / Double(factors.count),
            totalWords: words,
            distinctApps: apps,
            secondsSaved: max(0, typingSeconds - spokenSeconds)
        )
    }

    // MARK: - Deleting

    func delete(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        deleteAudio(for: entries[index])
        entries.remove(at: index)
        save()
    }

    func deleteAll() {
        for entry in entries { deleteAudio(for: entry) }
        entries.removeAll()
        save()
        file.flush()
        log.info("History cleared")
    }

    /// Enforces retention. Called on launch as well as on insert, so shortening the setting takes
    /// effect immediately rather than at the next dictation.
    func prune(retention: HistoryRetention) {
        var removed: [HistoryEntry] = []

        if let cutoff = retention.cutoff() {
            removed = entries.filter { $0.date < cutoff }
            entries.removeAll { $0.date < cutoff }
        }

        if entries.count > Self.hardLimit {
            removed.append(contentsOf: entries[Self.hardLimit...])
            entries.removeLast(entries.count - Self.hardLimit)
        }

        guard !removed.isEmpty else { return }
        for entry in removed { deleteAudio(for: entry) }
        log.info("Pruned \(removed.count) history entries")
        save()
    }

    func flush() { file.flush() }

    private func deleteAudio(for entry: HistoryEntry) {
        guard let name = entry.audioFileName else { return }
        try? FileManager.default.removeItem(at: AppDirectories.recordings.appendingPathComponent(name))
    }

    private func save() { file.save(entries) }
}
