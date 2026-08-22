import Foundation
import Observation

/// The live `Settings` value, saved whenever it changes.
///
/// Views bind straight to `store.settings.sound.playFeedbackSounds` and the write to disk takes
/// care of itself. `didSet` on the whole struct is deliberately coarse: settings change at human
/// speed, the file is a few kilobytes, and `JSONFileStore` already coalesces bursts.
@MainActor
@Observable
final class SettingsStore {
    var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            file.save(settings)
        }
    }

    @ObservationIgnored private let file: JSONFileStore<Settings>

    init(directory: URL = AppDirectories.support) {
        file = JSONFileStore(fileName: "settings.json", directory: directory)
        settings = Settings()
        settings = file.load() ?? Settings()
    }

    /// Called when the app is about to quit, so a change made a moment ago is not lost to the
    /// coalescing window.
    func flush() {
        file.flush()
    }

    /// Back to factory defaults. Does not touch the Keychain, history, or downloaded models —
    /// each of those has its own delete button, because "reset settings" should not silently
    /// destroy a 600 MB download or a month of transcripts.
    func resetToDefaults() {
        settings = Settings()
        file.flush()
    }
}
