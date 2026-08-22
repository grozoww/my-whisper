import SwiftUI

@main
struct OurWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        Window("OurWhisper", id: WindowID.main) {
            RootView()
                .environment(appState)
                .task { await appState.start() }
        }
        .defaultSize(width: 940, height: 660)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(appState)
        } label: {
            Image(systemName: appState.recordingState.menuBarSymbol)
                .accessibilityLabel(appState.recordingState.accessibilityLabel)
        }
    }
}

enum WindowID {
    static let main = "main"
}

/// The app is an `LSUIElement` accessory: no Dock icon, and it never steals focus on its own.
/// That matters more than it sounds — the whole product depends on another app keeping keyboard
/// focus while we record. Windows are shown only on explicit user action, and only then do we
/// briefly become a regular app so the window can come forward and accept input.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@MainActor
enum WindowPresenter {
    /// Bring a window forward from an accessory app. `openWindow` alone is not enough: an
    /// accessory app is not in the activation order, so the window would appear behind whatever
    /// the user was using.
    static func activate() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Drop back to accessory once the last window closes, so we leave the Dock and the
    /// command-tab list again.
    static func resignIfNoWindows() {
        guard NSApp.windows.allSatisfy({ !$0.isVisible || $0 is NSPanel }) else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}
