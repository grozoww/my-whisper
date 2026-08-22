import SwiftUI

@main
struct OurWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        Window("OurWhisper", id: WindowID.main) {
            RootView()
                .environment(appState)
                .task {
                    AppStateHolder.shared = appState
                    if ScreenshotMode.isActive {
                        await ScreenshotMode.run(appState: appState)
                    } else {
                        await appState.start()
                    }
                }
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

    /// Last chance to write coalesced settings, modes, vocabulary and history to disk. Without
    /// this, a change made in the last fraction of a second before quitting is lost.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppStateHolder.shared?.flushToDisk() }
    }
}

/// A weak pointer to the live `AppState`, so the app delegate can reach it on the way out.
///
/// The delegate is created by SwiftUI before the scene exists and receives no reference to it, and
/// `applicationWillTerminate` is the only place a final flush can happen.
@MainActor
enum AppStateHolder {
    static weak var shared: AppState?
}

@MainActor
enum WindowPresenter {
    /// Set by the Dock preference. When on, the app stays a regular app and never drops back to
    /// accessory, so the Dock icon does not blink out every time the window closes.
    static var showsDockIcon = false

    /// Bring a window forward from an accessory app. `openWindow` alone is not enough: an
    /// accessory app is not in the activation order, so the window would appear behind whatever
    /// the user was using.
    static func activate() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Ordering the window front explicitly matters on first launch: the scene exists from
        // launch, but an accessory app's window is not in the activation order, so without this
        // the app appears not to have started at all.
        for window in NSApp.windows where !(window is NSPanel) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Drop back to accessory once the last window closes, so we leave the Dock and the
    /// command-tab list again.
    static func resignIfNoWindows() {
        guard !showsDockIcon else { return }
        guard NSApp.windows.allSatisfy({ !$0.isVisible || $0 is NSPanel }) else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    static func setShowsDockIcon(_ shows: Bool) {
        showsDockIcon = shows
        NSApp.setActivationPolicy(shows ? .regular : .accessory)
        if shows { NSApp.activate(ignoringOtherApps: false) }
    }
}
