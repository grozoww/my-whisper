import FluidAudio
import Foundation
import OSLog

/// What is on disk, how big it is, and how to get rid of it.
///
/// The speech model is a 600 MB download the app makes on first launch. An app that does that
/// without showing you where it went, what it cost, or how to remove it is asking for a lot of
/// trust. This screen is the answer: every model the app can use, its state, its size, and a
/// delete button that actually deletes.
@MainActor
@Observable
final class ModelLibrary {
    /// One row in the library.
    struct Entry: Identifiable, Sendable {
        enum Kind: Sendable {
            /// Runs on this Mac. Has a size and can be deleted.
            case local
            /// Runs on someone else's. Has an API key instead of a download.
            case cloud
        }

        enum State: Equatable, Sendable {
            case notInstalled
            case downloading(Double)
            case installed(bytes: Int64)
            case failed(String)
            /// Cloud engines: configured or not.
            case ready
            case needsKey
        }

        let id: String
        let name: String
        let vendor: String
        let kind: Kind
        let detail: String
        let languages: String
        let licence: String
        var state: State
    }

    private let log = Logger(subsystem: "com.grozoww.ourwhisper", category: "models")

    private(set) var entries: [Entry] = []

    /// The provider that owns the speech model download, so the library can trigger and observe it
    /// rather than duplicating FluidAudio's download logic.
    private let parakeet: ParakeetProvider

    init(parakeet: ParakeetProvider) {
        self.parakeet = parakeet
        entries = [Self.parakeetEntry(state: .notInstalled), Self.sonioxEntry(state: .needsKey)]
    }

    // MARK: - Catalogue

    static let parakeetID = "parakeet-tdt-0.6b-v3"
    static let sonioxID = "soniox-cloud"

    private static func parakeetEntry(state: Entry.State) -> Entry {
        Entry(
            id: parakeetID,
            name: "Parakeet TDT 0.6B v3",
            vendor: "NVIDIA",
            kind: .local,
            detail: "The default. Runs on the Neural Engine, never leaves this Mac.",
            languages: "25 European languages",
            licence: "CC-BY-4.0",
            state: state
        )
    }

    private static func sonioxEntry(state: Entry.State) -> Entry {
        Entry(
            id: sonioxID,
            name: "Soniox",
            vendor: "Soniox",
            kind: .cloud,
            detail: "Optional. Covers the languages Parakeet cannot, including Chinese and Japanese.",
            languages: "60+ languages",
            licence: "Your own API key, billed by Soniox",
            state: state
        )
    }

    // MARK: - State

    /// Where FluidAudio keeps the speech model. Asked for rather than hardcoded, so the path stays
    /// right if the library changes it.
    static var parakeetDirectory: URL {
        AsrModels.defaultCacheDirectory(for: .v3)
    }

    func refresh() {
        let installed = AsrModels.modelsExist(at: Self.parakeetDirectory)
        let speechState: Entry.State = installed
            ? .installed(bytes: AppDirectories.size(of: Self.parakeetDirectory))
            : .notInstalled

        // A download in flight outranks what is on disk: the files are partially there and saying
        // "installed" would be a lie the progress bar immediately contradicts.
        let speech: Entry.State
        if case .downloading = state(of: Self.parakeetID) {
            speech = state(of: Self.parakeetID) ?? speechState
        } else {
            speech = speechState
        }

        entries = [
            Self.parakeetEntry(state: speech),
            Self.sonioxEntry(state: KeychainStore.has(.soniox) ? .ready : .needsKey),
        ]
    }

    private func state(of id: String) -> Entry.State? {
        entries.first { $0.id == id }?.state
    }

    private func setState(_ state: Entry.State, for id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].state = state
    }

    // MARK: - Actions

    func download(_ id: String) async {
        guard id == Self.parakeetID else { return }
        setState(.downloading(0), for: id)

        do {
            try await parakeet.prepare(progress: { [weak self] fraction in
                Task { @MainActor in self?.setState(.downloading(fraction), for: id) }
            })
            log.info("Speech model downloaded")
            refresh()
        } catch {
            log.error("Speech model download failed: \(error.localizedDescription, privacy: .public)")
            setState(.failed(error.localizedDescription), for: id)
        }
    }

    /// Unloads the model before deleting the files. Deleting CoreML models out from under a loaded
    /// `MLModel` is how you get a crash on the next dictation instead of a clean "not installed".
    func remove(_ id: String) async {
        guard id == Self.parakeetID else { return }
        await parakeet.unload()
        try? FileManager.default.removeItem(at: Self.parakeetDirectory)
        log.info("Speech model removed")
        refresh()
    }
}
