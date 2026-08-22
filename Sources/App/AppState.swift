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

    /// Name of the input device shown in the toolbar. Wired to real device enumeration in P1.
    var inputDeviceName: String = "Default input"

    func start() async {
        permissions.refresh()
        permissions.beginMonitoring()
    }
}
