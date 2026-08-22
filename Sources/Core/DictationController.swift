import AppKit
import OSLog

/// Drives one dictation: hotkey down, record, transcribe, clean up, paste, remember.
///
/// Everything here is ordered around one rule — the user's focused text field must survive the
/// whole cycle. That is why the target is captured before any UI appears and why the pill is a
/// non-activating panel.
///
/// The stages after transcription are all optional and all fail soft. Cleanup that cannot run
/// pastes the raw transcript; history that cannot be written loses a record, not the paste. The
/// text reaching the field is the only thing that is allowed to fail loudly.
@MainActor
@Observable
final class DictationController {
    enum Phase: Equatable {
        case idle
        case preparingModel(Double)
        case listening
        case transcribing
        case formatting
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    /// Surfaced on the Home screen so a missing permission is explained rather than just broken.
    private(set) var hotkeyArmed = false

    private let log = Logger(subsystem: "com.grozoww.ourwhisper", category: "dictation")

    private let capture = AudioCapture()
    private let hotkeys = HotkeyMonitor()
    private let injector = TextInjector()
    private let pill = PillWindowController()
    private let sounds = SoundPlayer()

    private let settings: SettingsStore
    private let modes: ModeStore
    private let vocabulary: VocabularyStore
    private let history: HistoryStore
    private let router: TranscriptionRouter
    private let refinement: RefinementPipeline

    private var levelTask: Task<Void, Never>?
    private var isRecording = false

    init(
        settings: SettingsStore,
        modes: ModeStore,
        vocabulary: VocabularyStore,
        history: HistoryStore,
        router: TranscriptionRouter,
        refinement: RefinementPipeline
    ) {
        self.settings = settings
        self.modes = modes
        self.vocabulary = vocabulary
        self.history = history
        self.router = router
        self.refinement = refinement
    }

    /// The engine the Home screen and Models library talk about. Exposed because the download it
    /// owns is the app's largest, and two screens need to show its state.
    var speechProvider: ParakeetProvider { router.parakeet }

    // MARK: - Lifecycle

    func start() {
        applySettings()
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
                await SelfTest.run(path: path, language: SelfTest.requestedLanguage, provider: router.parakeet)
            }
        }
    }

    /// Re-reads anything the hotkey layer caches. Called on launch and whenever the shortcut or
    /// its mode changes in Configuration, so a rebind takes effect without a restart.
    func applySettings() {
        let dictation = settings.settings.dictation
        let pushToTalk = dictation.pushToTalkChord.flatMap { $0.isEmpty ? nil : $0 }

        switch dictation.hotkeyMode {
        case .toggle:
            // Both are live at once. Someone who set a push-to-talk key expects it to work without
            // also having to change a mode picker.
            hotkeys.configure(toggle: dictation.toggleChord, pushToTalk: pushToTalk)
        case .pushToTalk:
            // The main chord holds rather than toggles, so nothing stays bound to toggle.
            hotkeys.configure(toggle: nil, pushToTalk: pushToTalk ?? dictation.toggleChord)
        }
    }

    /// Re-arms after the user grants Accessibility, which can happen long after launch.
    func armHotkeys() {
        hotkeyArmed = hotkeys.arm()
    }

    /// Screenshot mode only, alongside `PermissionsManager.poseAsGranted`. No event tap is
    /// installed during a screenshot run, so Home would otherwise be a picture of a warning.
    func poseAsArmed() {
        hotkeyArmed = true
    }

    private func prepareModel() async {
        // Nothing to download when the user runs entirely on the cloud engine, and downloading
        // 600 MB they asked not to use would be rude.
        guard router.plannedProviderID(for: settings.settings.dictation) == .parakeet else {
            phase = .idle
            return
        }

        do {
            phase = .preparingModel(0)
            try await router.parakeet.prepare(progress: { [weak self] fraction in
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

        // Fail here rather than after recording. Telling someone their language needs a key they
        // have not added is useful before they speak and infuriating after.
        do {
            _ = try router.provider(for: settings.settings.dictation)
        } catch {
            notify(error.localizedDescription)
            return
        }

        // Before anything is drawn. Showing the pill first would let `frontmostApplication` change
        // under us, and the text would land in the wrong app.
        injector.captureTarget()

        do {
            try capture.start(deviceUID: settings.settings.sound.inputDeviceUID)
        } catch {
            log.error("Capture failed: \(error.localizedDescription, privacy: .public)")
            notify(error.localizedDescription)
            return
        }

        isRecording = true
        hotkeys.isRecording = true
        phase = .listening
        playFeedback(settings.settings.sound.startSound)
        showPill(.listening)
        startLevelUpdates()
    }

    private func finishRecording() {
        guard isRecording else { return }
        isRecording = false
        hotkeys.isRecording = false
        stopLevelUpdates()

        let samples = capture.stop()
        phase = .transcribing
        pill.setPhase(.transcribing)
        playFeedback(settings.settings.sound.stopSound)

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
        let current = settings.settings

        do {
            let provider = try router.provider(for: current.dictation)
            let result = try await provider.transcribe(samples: samples, language: current.dictation.language)
            guard !result.text.isEmpty else {
                notify("Nothing was said")
                return
            }

            log.info("Transcribed \(result.audioDuration, format: .fixed(precision: 1))s in \(result.processingTime, format: .fixed(precision: 2))s (\(result.realtimeFactor, format: .fixed(precision: 0))x realtime)")

            let mode = modes.resolve(
                settings: current.refinement,
                frontmostBundleID: injector.targetBundleID
            )

            // The pill only says "cleaning up" when something slow is actually happening. Rules
            // finish in microseconds, and a flash of a stage nobody waited for reads as jitter.
            let willUseModel = current.refinement.isEnabled
                && current.refinement.useOnDeviceModel
                && !mode.instructions.isEmpty
            if willUseModel {
                phase = .formatting
                pill.setPhase(.formatting)
            }

            let refined = await refinement.refine(
                result.text,
                mode: mode,
                settings: current.refinement,
                vocabulary: vocabulary.enabledEntries,
                language: current.dictation.language
            )

            let method = try await injector.inject(refined.text)
            log.debug("Injected via \(method.rawValue, privacy: .public)")

            record(
                raw: result.text,
                final: refined.text,
                mode: mode,
                transcription: result,
                usedModel: refined.usedModel,
                samples: samples,
                settings: current
            )

            phase = .idle
            pill.setPhase(.success(injector.targetName ?? "Pasted"))
            pill.dismiss(after: .milliseconds(700))
        } catch {
            log.error("Dictation failed: \(error.localizedDescription, privacy: .public)")
            notify(error.localizedDescription)
        }
    }

    // MARK: - History

    private func record(
        raw: String,
        final: String,
        mode: Mode,
        transcription: Transcription,
        usedModel: Bool,
        samples: [Float],
        settings current: Settings
    ) {
        guard current.history.isEnabled else { return }

        let audioFileName = current.history.keepAudio ? saveAudio(samples) : nil

        history.record(
            HistoryEntry(
                rawText: raw,
                finalText: final,
                appName: injector.targetName,
                appBundleID: injector.targetBundleID,
                modeName: mode.name,
                providerID: router.plannedProviderID(for: current.dictation),
                language: current.dictation.language,
                usedModel: usedModel,
                audioDuration: transcription.audioDuration,
                processingTime: transcription.processingTime,
                audioFileName: audioFileName
            ),
            settings: current.history
        )
    }

    /// Writes the recording next to its history entry. Failure is logged and ignored: a missing
    /// audio file costs the user a replay, and refusing the whole entry over it would cost them the
    /// transcript too.
    private func saveAudio(_ samples: [Float]) -> String? {
        let name = "\(UUID().uuidString).wav"
        let url = AppDirectories.recordings.appendingPathComponent(name)
        do {
            try WAVEncoder.encode(samples: samples).write(to: url, options: .atomic)
            return name
        } catch {
            log.error("Could not save recording: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Feedback

    private func showPill(_ phase: PillModel.Phase) {
        guard settings.settings.appearance.showPill else { return }
        pill.show()
        pill.setPhase(phase)
    }

    private func playFeedback(_ sound: FeedbackSound) {
        let soundSettings = settings.settings.sound
        guard soundSettings.playFeedbackSounds else { return }
        sounds.play(sound, volume: soundSettings.feedbackVolume)
    }

    private func notify(_ message: String) {
        phase = .failed(message)
        playFeedback(settings.settings.sound.errorSound)
        // `show()` resets the model, so the phase has to be set after it — the other way round
        // and the pill spends its 2.5 seconds showing audio bars instead of the error.
        pill.show()
        pill.setPhase(.failure(message))
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
