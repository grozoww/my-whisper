import SwiftUI

/// The controls offering a release the user does not have yet.
///
/// Shared with the Configuration screen's Updates section, because the "Check now" button there
/// arrives at the same answer and showing it with nothing to press would be a dead end.
///
/// `refusal` is passed in rather than read here: working it out means reading this app's own code
/// signature, which is a round trip to the security daemon, and nothing in a SwiftUI body may ask
/// the system a question. Each screen reads it once in a `.task` and hands it down.
struct UpdateActions: View {
    @Environment(AppState.self) private var appState
    let release: UpdateChecker.Release
    /// Passed in rather than read from `appState` so every phase can be built in a test. A
    /// `switch` inside a `ViewBuilder` compiles whichever branch is wrong.
    let phase: UpdateInstaller.Phase
    let refusal: String?

    var body: some View {
        HStack(spacing: 8) {
            switch phase {
            case .downloading(let fraction):
                // A bar when the release said how big the image is, a spinner when it did not —
                // rather than a bar pinned at nothing for the whole download.
                if let fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 110)
                } else {
                    ProgressView().progressViewStyle(.circular).controlSize(.small)
                }
            case .verifying, .installing, .restarting:
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            case .installedNeedsRestart:
                Button("Quit OurWhisper") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderedProminent)
            case .idle, .failed:
                Link("Release notes", destination: release.url)

                Button("Skip") {
                    appState.settings.settings.updates.skippedVersion = release.version
                    appState.updates.dismissAvailableRelease()
                    appState.installer.dismissFailure()
                }
                .buttonStyle(.bordered)

                if release.dmg != nil, refusal == nil {
                    Button("Update and restart") {
                        Task { await appState.installer.install(release) }
                    }
                    .buttonStyle(.borderedProminent)
                    // Not mid-dictation: installing ends with the app quitting, and the sentence
                    // being spoken would go with it.
                    .disabled(appState.recordingState != .idle)
                }
            }
        }
    }

    /// What the row says under its title — why it cannot install, why it just did not, or what the
    /// release is called. Pure, so both screens say the same thing without either owning it.
    nonisolated static func detail(
        phase: UpdateInstaller.Phase,
        refusal: String?,
        release: UpdateChecker.Release
    ) -> String {
        switch phase {
        case .failed(let message): message
        case .downloading: "Downloading \(release.dmg?.name ?? "the update")…"
        case .verifying: "Checking the download against this app's signature…"
        case .installing: "Installing…"
        case .restarting: "Restarting into \(release.version)…"
        case .installedNeedsRestart:
            "Version \(release.version) is installed. Quit OurWhisper and open it again to finish."
        case .idle: refusal ?? release.title
        }
    }

    nonisolated static func isWarning(phase: UpdateInstaller.Phase, refusal: String?) -> Bool {
        if case .failed = phase { return true }
        // Not a warning: the update is installed and correct, and only the restart is outstanding.
        if case .installedNeedsRestart = phase { return false }
        return refusal != nil
    }
}

/// The card on the Home screen when a newer release exists.
struct UpdateBanner: View {
    @Environment(AppState.self) private var appState
    let release: UpdateChecker.Release

    @State private var refusal: String?

    var body: some View {
        let phase = appState.installer.phase
        let warning = UpdateActions.isWarning(phase: phase, refusal: refusal)

        Card {
            SettingsRow(
                symbol: warning ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill",
                title: "Version \(release.version) is available",
                detail: UpdateActions.detail(phase: phase, refusal: refusal, release: release),
                tint: warning ? .orange : .accentColor
            ) {
                UpdateActions(release: release, phase: phase, refusal: refusal)
            }
        }
        .task { refusal = appState.installer.refusal }
    }
}
