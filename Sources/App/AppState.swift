import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    /// Where the app is in the record → transcribe → format → paste cycle. Drives the menu bar
    /// glyph and the pill overlay, so every stage the user waits on needs its own case.
    enum RecordingState: Equatable {
        case idle
        case listening
        case transcribing
        case formatting
        case failed(String)

        var menuBarSymbol: String {
            switch self {
            case .idle: "mic"
            case .listening: "mic.fill"
            case .transcribing: "waveform"
            case .formatting: "sparkles"
            case .failed: "exclamationmark.triangle.fill"
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .idle: "OurWhisper, idle"
            case .listening: "OurWhisper, listening"
            case .transcribing: "OurWhisper, transcribing"
            case .formatting: "OurWhisper, formatting"
            case .failed(let message): "OurWhisper, error: \(message)"
            }
        }
    }

    var recordingState: RecordingState = .idle
    var selectedSection: NavigationSection = .home
    let permissions = PermissionsManager()
    let dictation = DictationController()

    /// Name of the input device shown in the toolbar. Real device enumeration lands in P4's
    /// Sound settings; until then this is the system default.
    var inputDeviceName: String = "Default input"

    private var accessibilityWatcher: Task<Void, Never>?

    func start() async {
        permissions.refresh()
        permissions.beginMonitoring()
        dictation.start()
        watchAccessibility()
    }

    /// The hotkey tap cannot be installed until Accessibility is granted, and the user usually
    /// grants it minutes after launch. Without this the app would need a restart to work.
    private func watchAccessibility() {
        guard accessibilityWatcher == nil else { return }
        accessibilityWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                if self.permissions.accessibility.isGranted, !self.dictation.hotkeyArmed {
                    self.dictation.armHotkeys()
                }
            }
        }
    }
}
