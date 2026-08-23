import Foundation
import OSLog
import ServiceManagement

/// Whether macOS starts OurWhisper when the user logs in.
///
/// Deliberately *not* a field in `Settings`. macOS owns this state — the user can switch the login
/// item off in System Settings › General › Login Items and the app is never told — so a stored
/// copy would drift and the toggle would end up lying about what the system will actually do.
/// Every read goes to `SMAppService`.
///
/// `SMAppService.mainApp` registers the running bundle by path, with no helper target and no
/// privileged install step. That has the same consequence as Accessibility permission does: a
/// debug build in DerivedData registers *that* copy, so a login item added from a development
/// build points somewhere the user will eventually delete. Register from /Applications.
enum LaunchAtLogin {
    private static let log = Logger(subsystem: "com.grozoww.ourwhisper", category: "login")

    /// What macOS will do at the next login, as macOS sees it.
    ///
    /// Every read is an XPC round trip to the background task daemon — a few milliseconds. Read it
    /// into state; never from a SwiftUI body, which is evaluated far more often than this changes.
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    /// `nil` when the system state now matches what was asked for, or a sentence saying why not.
    ///
    /// Registration can fail for reasons the user has to fix themselves — most often because they
    /// previously switched the item off in System Settings, which macOS reports as
    /// `.requiresApproval` and refuses to override from code. The switch snapping silently back
    /// is not an answer, so the reason comes back with it and the row says it out loud.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                // Registering an already-registered app throws rather than doing nothing.
                guard status != .enabled else { return nil }
                try SMAppService.mainApp.register()
            } else {
                guard status != .notRegistered else { return nil }
                try SMAppService.mainApp.unregister()
            }
            guard isEnabled != enabled else { return nil }
            return "macOS did not \(enabled ? "add" : "remove") the login item. Do it by hand in System Settings › General › Login Items."
        } catch {
            log.error("Could not \(enabled ? "register" : "unregister") the login item: \(error.localizedDescription, privacy: .public)")
            return "macOS refused: \(error.localizedDescription) Add OurWhisper by hand in System Settings › General › Login Items."
        }
    }

    /// Sentence for the settings row, written to say what to do about it rather than to name a
    /// status code.
    static var explanation: String { explanation(for: status) }

    /// Takes the status rather than reading it, so every branch can be covered by a test on a
    /// machine where only one of them is ever true.
    static func explanation(for status: SMAppService.Status) -> String {
        switch status {
        case .enabled:
            "OurWhisper starts with your Mac. It opens straight to the menu bar, with no window."
        case .requiresApproval:
            "macOS has this switched off. Turn OurWhisper on in System Settings › General › Login Items — it cannot be re-enabled from here."
        // `.notFound` is not "the app is in the wrong place": it is also what an app that has
        // simply never registered reports, and registering from that state works. Treating it as
        // an error is what left the switch greyed out on a correctly installed copy.
        case .notFound, .notRegistered:
            "Start OurWhisper at login so the hotkey works without opening anything first."
        default:
            "Start OurWhisper at login so the hotkey works without opening anything first."
        }
    }

    /// Only the user can undo a login item they switched off themselves, so the row needs a way to
    /// send them to the pane that owns it.
    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
