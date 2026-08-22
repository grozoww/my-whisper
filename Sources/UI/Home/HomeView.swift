import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                StatsCard()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Get started")
                        .font(.system(size: 17, weight: .semibold))

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

                if appState.permissions.allGranted {
                    Card {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.system(size: 18))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Permissions are set")
                                    .font(.system(size: 14, weight: .medium))
                                Text("Recording and transcription arrive in P1.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(14)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
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
                // so offering "Allow" again would just do nothing and look broken.
                Button("Open Settings") { appState.permissions.openSettings(for: settingsPane) }
                    .buttonStyle(.bordered)
            }
        }
        .padding(14)
    }
}
