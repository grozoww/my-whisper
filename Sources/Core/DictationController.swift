import AppKit
import OSLog

/// Drives one dictation: hotkey down, record, transcribe, paste, done.
///
/// Everything here is ordered around one rule — the user's focused text field must survive the
/// whole cycle. That is why the target is captured before any UI appears and why the pill is a
/// non-activating panel.
@MainActor
@Observable
final class DictationController {
    enum Phase: Equatable {
        case idle
        case preparingModel(Double)
        case listening
        case transcribing
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    /// Surfaced on the Home screen so a missing permission is explained rather than just broken.
    private(set) var hotkeyArmed = false

    var language: SpeechLanguage = .auto

    private let log = Logger(subsystem: "com.grozoww.ourwhisper", category: "dictation")

    private let capture = AudioCapture()
    private let hotkeys = HotkeyMonitor()
    private let injector = TextInjector()
    private let pill = PillWindowController()
    private let provider: any TranscriptionProvider = ParakeetProvider()

    private var levelTask: Task<Void, Never>?
    private var isRecording = false

    // MARK: - Lifecycle

    func start() {
        hotkeys.configure(toggle: .hyper, pushToTalk: nil)
        hotkeys.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .toggle: self.toggle()
            case .pressStart: self.beginRecording()
            case .pressEnd: self.finishRecording()
            case .cancel: self.cancel()
            }
        }
        armHotkeys()

        // Load the model now rather than on the first hotkey press. A 600 MB download the first
        // time you try to dictate would feel like the app is broken.
        Task {
            await prepareModel()
            if let path = SelfTest.requestedPath {
                await SelfTest.run(path: path, language: SelfTest.requestedLanguage, provider: provider)
            }
        }
    }

    /// Re-arms after the user grants Accessibility, which can happen long after launch.
    func armHotkeys() {
        hotkeyArmed = hotkeys.arm()
    }

    private func prepareModel() async {
        do {
            phase = .preparingModel(0)
            try await provider.prepare(progress: { [weak self] fraction in
                Task { @MainActor in
                    guard let self, case .preparingModel = self.phase else { return }
                    self.phase = .preparingModel(fraction)
                }
            })
            phase = .idle
            log.info("Speech model ready")
        } catch {
            phase = .failed(error.localizedDescription)
            log.error("Model preparation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Recording

    func toggle() {
        isRecording ? finishRecording() : beginRecording()
    }

    private func beginRecording() {
        guard !isRecording else { return }
        if case .preparingModel = phase {
            notify("Speech model is still downloading")
            return
        }

        // Before anything is drawn. Showing the pill first would let `frontmostApplication` change
        // under us, and the text would land in the wrong app.
        injector.captureTarget()

        do {
            try capture.start()
        } catch {
            log.error("Capture failed: \(error.localizedDescription, privacy: .public)")
            notify(error.localizedDescription)
            return
        }

        isRecording = true
        hotkeys.isRecording = true
        phase = .listening
        pill.show()
        startLevelUpdates()
    }

    private func finishRecording() {
        guard isRecording else { return }
        isRecording = false
        hotkeys.isRecording = false
        stopLevelUpdates()

        let samples = capture.stop()
        phase = .transcribing
        pill.pillModel.phase = .transcribing

        Task { await transcribeAndInject(samples) }
    }

    func cancel() {
        guard isRecording else { return }
        isRecording = false
        hotkeys.isRecording = false
        stopLevelUpdates()
        _ = capture.stop()
        phase = .idle
        pill.hide()
        log.debug("Recording cancelled")
    }

    private func transcribeAndInject(_ samples: [Float]) async {
        do {
            let result = try await provider.transcribe(samples: samples, language: language)
            guard !result.text.isEmpty else {
                notify("Nothing was said")
                return
            }

            log.info("Transcribed \(result.audioDuration, format: .fixed(precision: 1))s in \(result.processingTime, format: .fixed(precision: 2))s (\(result.realtimeFactor, format: .fixed(precision: 0))x realtime)")

            // P3 inserts the formatting pipeline between here and injection.
            let method = try await injector.inject(result.text)
            log.debug("Injected via \(method.rawValue, privacy: .public)")

            phase = .idle
            pill.pillModel.phase = .success(injector.targetName ?? "Pasted")
            pill.dismiss(after: .milliseconds(700))
        } catch {
            log.error("Dictation failed: \(error.localizedDescription, privacy: .public)")
            notify(error.localizedDescription)
        }
    }

    private func notify(_ message: String) {
        phase = .failed(message)
        pill.pillModel.phase = .failure(message)
        pill.show()
        pill.dismiss(after: .seconds(2.5))
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if case .failed = phase { phase = .idle }
        }
    }

    // MARK: - Level metering

    /// 30 Hz is enough for the bars to look alive and cheap enough not to matter. Reading the
    /// level is a lock and a float copy; no audio work happens on this timer.
    private func startLevelUpdates() {
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.pill.pillModel.push(level: self.capture.currentLevel)
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func stopLevelUpdates() {
        levelTask?.cancel()
        levelTask = nil
    }
}
