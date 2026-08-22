import Foundation
import OSLog

/// Reads and writes one `Codable` value to one JSON file.
///
/// Two things here are not incidental. Writes are atomic, because the alternative is a half-written
/// settings file after a crash and an app that comes back with no configuration. And writes are
/// coalesced: settings screens fire a change per keystroke, and hitting the disk on each one turns
/// typing a prompt into a few hundred file writes.
@MainActor
final class JSONFileStore<Value: Codable & Sendable> {
    private let url: URL
    private let log = Logger(subsystem: "com.grozoww.ourwhisper", category: "storage")

    /// Long enough to swallow a burst of typing, short enough that quitting right after a change
    /// still saves it — `flush()` covers the rest.
    private static var coalesceInterval: Duration { .milliseconds(400) }

    private var pending: Value?
    private var writeTask: Task<Void, Never>?

    /// - Parameter directory: Where the file lives. Injected rather than assumed so tests can
    ///   point a store at a temporary directory — a test that wrote to the real Application
    ///   Support directory would destroy the settings and history of whoever ran it.
    init(fileName: String, directory: URL = AppDirectories.support) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.url = directory.appendingPathComponent(fileName, isDirectory: false)
    }

    func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            // A file we cannot read is more likely an older schema than corruption. Renaming it
            // rather than deleting means the user's modes and vocabulary are still recoverable by
            // hand, and the app starts with defaults instead of refusing to run.
            log.error("Could not decode \(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            let backup = url.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            return nil
        }
    }

    func save(_ value: Value) {
        pending = value
        writeTask?.cancel()
        writeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.coalesceInterval)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Writes any coalesced change immediately.
    func flush() {
        guard let value = pending else { return }
        pending = nil
        writeTask?.cancel()
        writeTask = nil

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            log.error("Could not write \(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
