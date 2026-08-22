import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var appState

    private var permissionsPending: Bool { !appState.permissions.allGranted }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                StatsCard()

                if permissionsPending {
                    section("Finish setup") {
                        Card {
                            PermissionRow(
                                title: "Allow microphone access",
                                detail: "OurWhisper only opens the mic while you hold the hotkey.",
                                status: appState.permissions.microphone,
                                action: { Task { await appState.permissions.requestMicrophone() } },
                                settingsPane: .microphone
                            )
                            Divider().padding(.leading, 52)
                            PermissionRow(
                                title: "Allow accessibility access",
                                detail: "Needed to watch for the hotkey and paste into the focused field.",
                                status: appState.permissions.accessibility,
                                action: { appState.permissions.requestAccessibility() },
                                settingsPane: .accessibility
                            )
                        }
                    }
                }

                section("Get started") {
                    Card {
                        HotkeyRow(armed: appState.dictation.hotkeyArmed)
                        Divider().padding(.leading, 52)
                        ModelRow(phase: appState.dictation.phase)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 17, weight: .semibold))
            content()
        }
    }
}

// MARK: - Rows

private struct HotkeyRow: View {
    let armed: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: armed ? "record.circle" : "record.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(armed ? Color.accentColor : Color.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("Start recording").font(.system(size: 14, weight: .medium))
                Text(armed
                     ? "Hold these keys together, speak, then press again to finish."
                     : "Waiting for Accessibility permission before the hotkey can be watched.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)
            KeycapRow(glyphs: HotkeyChord.hyper.displayGlyphs)
                .opacity(armed ? 1 : 0.4)
        }
        .padding(14)
    }
}

private struct ModelRow: View {
    let phase: DictationController.Phase

    var body: some View {
        HStack(spacing: 12) {
            icon.font(.system(size: 18)).frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("Speech model").font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if case .preparingModel(let fraction) = phase {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 110)
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private var icon: some View {
        switch phase {
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .preparingModel:
            Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
        default:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
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
        case .idle:
            "Parakeet TDT v3, running offline on the Neural Engine."
        }
    }
}

private struct StatsCard: View {
    var body: some View {
        Card {
            HStack(spacing: 0) {
                stat("—", "Average speed")
                stat("—", "Words")
                stat("—", "Apps used")
                stat("—", "Saved all time")
            }
            .padding(.vertical, 18)
        }
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
        HStack(spacing: 12) {
            Image(systemName: status.isGranted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 18))
                .foregroundStyle(status.isGranted ? Color.green : Color.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

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
        .padding(14)
    }
}
