import AppKit
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

    var selectedSection: NavigationSection = .home

    let permissions = PermissionsManager()
    let updates = UpdateChecker()

    let settings: SettingsStore
    let modes: ModeStore
    let vocabulary: VocabularyStore
    let history: HistoryStore
    let onDeviceRefiner: OnDeviceRefiner
    let router: TranscriptionRouter
    let models: ModelLibrary
    let dictation: DictationController

    /// Mirrors `dictation.phase` for the menu bar and the sidebar, which do not need to know about
    /// the controller's extra states.
    var recordingState: RecordingState {
        switch dictation.phase {
        case .idle, .preparingModel: .idle
        case .listening: .listening
        case .transcribing: .transcribing
        case .formatting: .formatting
        case .failed(let message): .failed(message)
        }
    }

    /// Name of the input device shown in the toolbar.
    var inputDeviceName: String {
        guard let uid = settings.settings.sound.inputDeviceUID else { return "Default input" }
        return AudioDevices.inputs().first { $0.id == uid }?.name ?? "Default input"
    }

    private var accessibilityWatcher: Task<Void, Never>?
    private var didStart = false

    /// - Parameter directory: Where the stores keep their JSON. Injected only so tests can render
    ///   the real screens against real stores without touching the user's data.
    init(directory: URL = AppDirectories.support) {
        let router = TranscriptionRouter()
        let settings = SettingsStore(directory: directory)
        let modes = ModeStore(directory: directory)
        let vocabulary = VocabularyStore(directory: directory)
        let history = HistoryStore(directory: directory)
        let onDevice = OnDeviceRefiner()

        self.settings = settings
        self.modes = modes
        self.vocabulary = vocabulary
        self.history = history
        self.onDeviceRefiner = onDevice
        self.router = router
        self.models = ModelLibrary(parakeet: router.parakeet)
        self.dictation = DictationController(
            settings: settings,
            modes: modes,
            vocabulary: vocabulary,
            history: history,
            router: router,
            refinement: RefinementPipeline(onDevice: onDevice)
        )
    }

    func start() async {
        // The unit tests run against the app bundle as their host, so launching it must not kick
        // off a 600 MB model download or install a system-wide event tap. Nothing in `start()` is
        // under test; the pieces it wires together are tested directly.
        guard !Self.isRunningTests else { return }
        guard !didStart else { return }
        didStart = true

        settings.settings.appearance.theme.apply()
        WindowPresenter.setShowsDockIcon(settings.settings.appearance.showInDock)
        // Turning history off stops new entries; it does not destroy old ones. Pruning is always
        // against the retention the user actually chose.
        history.prune(retention: settings.settings.history.retention)
        models.refresh()

        permissions.refresh()
        permissions.beginMonitoring()
        dictation.start()
        watchAccessibility()

        // An accessory app with no Dock icon that silently does nothing is indistinguishable from
        // an app that failed to launch. If it cannot work yet, say so on screen rather than
        // waiting for a hotkey press that cannot possibly be heard.
        if let requested = NavigationSection.requested {
            selectedSection = requested
            WindowPresenter.activate()
        } else if !permissions.allGranted {
            selectedSection = .home
            WindowPresenter.activate()
        }

        if settings.settings.updates.checkAutomatically {
            await updates.check(skippedVersion: settings.settings.updates.skippedVersion)
            settings.settings.updates.lastCheck = Date()
        }
    }

    static var isRunningTests: Bool { AppDirectories.isRunningTests }

    /// Called from the app delegate on the way out, so a setting changed a moment before quitting
    /// is on disk rather than sitting in the coalescing window.
    func flushToDisk() {
        settings.flush()
        modes.flush()
        vocabulary.flush()
        history.flush()
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
