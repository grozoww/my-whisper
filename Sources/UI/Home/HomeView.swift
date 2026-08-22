import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var appState

    private var permissionsPending: Bool { !appState.permissions.allGranted }

    var body: some View {
        SettingsPage {
            StatsCard(stats: appState.history.stats)

            if case .available(let release) = appState.updates.state {
                UpdateBanner(release: release)
            }

            if permissionsPending {
                SettingsSection(title: "Finish setup") {
                    PermissionRow(
                        title: "Allow microphone access",
                        detail: "OurWhisper only opens the mic while you hold the hotkey.",
                        status: appState.permissions.microphone,
                        action: { Task { await appState.permissions.requestMicrophone() } },
                        settingsPane: .microphone
                    )
                    RowDivider()
                    PermissionRow(
                        title: "Allow accessibility access",
                        detail: "Needed to watch for the hotkey and paste into the focused field.",
                        status: appState.permissions.accessibility,
                        action: { appState.permissions.requestAccessibility() },
                        settingsPane: .accessibility
                    )

                    if !appState.permissions.accessibility.isGranted {
                        RowDivider()
                        GrantedButStillDeniedRow()
                    }
                }
            }

            SettingsSection(title: "Get started") {
                HotkeyRow(
                    armed: appState.dictation.hotkeyArmed,
                    chord: appState.settings.settings.dictation.toggleChord,
                    mode: appState.settings.settings.dictation.hotkeyMode
                )
                RowDivider()
                ModelRow(phase: appState.dictation.phase, provider: plannedProvider)
                RowDivider()
                ModeRow(mode: activeMode, autoSwitch: appState.settings.settings.refinement.autoSwitchByApp)
            }
        }
    }

    private var plannedProvider: TranscriptionProviderID {
        appState.router.plannedProviderID(for: appState.settings.settings.dictation)
    }

    private var activeMode: Mode {
        appState.modes.resolve(settings: appState.settings.settings.refinement, frontmostBundleID: nil)
    }
}

// MARK: - Rows

private struct HotkeyRow: View {
    let armed: Bool
    let chord: HotkeyChord
    let mode: HotkeyMode

    var body: some View {
        SettingsRow(
            symbol: armed ? "record.circle" : "record.circle.fill",
            title: "Start recording",
            detail: armed ? instruction : "Waiting for Accessibility permission before the hotkey can be watched.",
            tint: armed ? .accentColor : .secondary
        ) {
            KeycapRow(glyphs: chord.displayGlyphs)
                .opacity(armed ? 1 : 0.4)
        }
    }

    private var instruction: String {
        switch mode {
        case .toggle: "Press these keys together, speak, then press again to finish."
        case .pushToTalk: "Hold these keys, speak, and let go to finish."
        }
    }
}

private struct ModelRow: View {
    let phase: DictationController.Phase
    let provider: TranscriptionProviderID

    var body: some View {
        SettingsRow(symbol: symbol, title: "Speech model", detail: detail, tint: tint) {
            if case .preparingModel(let fraction) = phase {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 110)
            }
        }
    }

    private var symbol: String {
        switch phase {
        case .failed: "exclamationmark.triangle.fill"
        case .preparingModel: "arrow.down.circle"
        default: provider == .soniox ? "cloud" : "checkmark.circle.fill"
        }
    }

    private var tint: Color {
        switch phase {
        case .failed: .orange
        case .preparingModel: .secondary
        default: provider == .soniox ? .blue : .green
        }
    }

    private var detail: String {
        switch phase {
        case .preparingModel(let fraction):
            "Downloading Parakeet TDT v3 — \(Int(fraction * 100))%"
        case .failed(let message):
            message
        case .listening:
            "Listening…"
        case .transcribing:
            "Transcribing…"
        case .formatting:
            "Cleaning up…"
        case .idle:
            provider == .soniox
                ? "Soniox, in the cloud. Audio leaves this Mac for this language."
                : "Parakeet TDT v3, running offline on the Neural Engine."
        }
    }
}

private struct ModeRow: View {
    let mode: Mode
    let autoSwitch: Bool

    var body: some View {
        SettingsRow(
            symbol: mode.symbol,
            title: "Mode",
            detail: autoSwitch
                ? "\(mode.name) — switches automatically to match the app you type into."
                : mode.name,
            tint: mode.tint.color
        ) {
            EmptyView()
        }
    }
}

private struct UpdateBanner: View {
    @Environment(AppState.self) private var appState
    let release: UpdateChecker.Release

    var body: some View {
        Card {
            SettingsRow(
                symbol: "arrow.down.circle.fill",
                title: "Version \(release.version) is available",
                detail: release.title,
                tint: .accentColor
            ) {
                HStack(spacing: 8) {
                    Button("Skip") {
                        appState.settings.settings.updates.skippedVersion = release.version
                        appState.updates.dismissAvailableRelease()
                    }
                    .buttonStyle(.bordered)

                    Link("Release notes", destination: release.url)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

/// The "I granted it and it still says no" row.
///
/// Accessibility is granted to an app *bundle at a path*. A debug build lives in DerivedData, and
/// a second clone or a git worktree produces a second OurWhisper.app — so System Settings shows a
/// ticked OurWhisper while the copy you just launched has been granted nothing. Nothing in the
/// permission API can tell you that; only seeing the two paths side by side can.
private struct GrantedButStillDeniedRow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(
                symbol: "questionmark.circle",
                title: "Already granted it and this still says no?",
                detail: appState.permissions.hasOtherBuilds
                    ? "There is more than one OurWhisper.app on this Mac. macOS grants Accessibility to one app bundle at one path, so a permission granted to another build does not apply here. Remove every OurWhisper from the Accessibility list, then add the exact app below."
                    : "macOS grants Accessibility to one app bundle at one path. Remove OurWhisper from the Accessibility list, then add back the exact app below.",
                tint: .orange
            ) {
                Button("Reveal this build") {
                    NSWorkspace.shared.activateFileViewerSelecting([appState.permissions.runningBundleURL])
                }
                .buttonStyle(.bordered)
            }

            Text(appState.permissions.runningBundleURL.path(percentEncoded: false))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.horizontal, 52)
                .padding(.bottom, 14)
        }
    }
}

private struct StatsCard: View {
    let stats: HistoryStore.Stats

    var body: some View {
        Card {
            HStack(spacing: 0) {
                stat(speed, "Average speed")
                stat(stats.totalWords == 0 ? "—" : stats.totalWords.formatted(), "Words")
                stat(stats.distinctApps == 0 ? "—" : "\(stats.distinctApps)", "Apps used")
                stat(saved, "Saved all time")
            }
            .padding(.vertical, 18)
        }
    }

    private var speed: String {
        stats.averageRealtimeFactor > 0 ? "\(Int(stats.averageRealtimeFactor.rounded()))×" : "—"
    }

    /// Rounded to the unit above, because "3 h" is the honest resolution for an estimate built on
    /// an assumed typing speed. Minutes would imply a precision this number does not have.
    private var saved: String {
        let seconds = stats.secondsSaved
        guard seconds >= 60 else { return "—" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) min" }
        return "\(Int((seconds / 3_600).rounded())) h"
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 21, weight: .semibold))
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let status: PermissionsManager.Status
    let action: () -> Void
    let settingsPane: PermissionsManager.Pane

    @Environment(AppState.self) private var appState

    var body: some View {
        SettingsRow(
            symbol: status.isGranted ? "checkmark.circle.fill" : "circle.dashed",
            title: title,
            detail: detail,
            tint: status.isGranted ? .green : .secondary
        ) {
            switch status {
            case .granted:
                Text("Granted").font(.system(size: 12)).foregroundStyle(.secondary)
            case .notDetermined:
                Button("Allow", action: action).buttonStyle(.borderedProminent)
            case .denied:
                // macOS shows its prompt only once. After a denial the only route is Settings,
                // so offering "Allow" again would do nothing and look broken.
                Button("Open Settings") { appState.permissions.openSettings(for: settingsPane) }
                    .buttonStyle(.bordered)
            }
        }
    }
}
