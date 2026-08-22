import SwiftUI

struct MenuBarContent: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if !appState.permissions.allGranted {
                Button("Finish setup…") { showWindow(.home) }
                Divider()
            }

            Text(statusLine)

            Divider()

            Button("Settings…") { showWindow(.configuration) }
                .keyboardShortcut(",", modifiers: .command)
            Button("History") { showWindow(.history) }

            Divider()

            Button("Quit OurWhisper") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
    }

    private var statusLine: String {
        switch appState.recordingState {
        case .idle: "Ready"
        case .listening: "Listening…"
        case .transcribing: "Transcribing…"
        case .formatting: "Cleaning up…"
        case .failed(let message): "Error: \(message)"
        }
    }

    private func showWindow(_ section: NavigationSection) {
        appState.selectedSection = section
        WindowPresenter.activate()
        openWindow(id: WindowID.main)
    }
}
