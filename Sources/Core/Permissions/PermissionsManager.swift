import AVFoundation
import AppKit
import ApplicationServices
import Observation

/// Tracks the two permissions the app cannot work without, and knows how to get the user to the
/// exact settings pane for each.
///
/// Accessibility is the awkward one. There is no API to request it and no callback when it
/// changes: `AXIsProcessTrustedWithOptions` only opens System Settings and returns the *current*
/// value. So we poll while the app is running. Polling is also what catches the user revoking the
/// permission mid-session, which otherwise breaks dictation silently.
@MainActor
@Observable
final class PermissionsManager {
    enum Status: Equatable {
        case granted
        case denied
        case notDetermined

        var isGranted: Bool { self == .granted }
    }

    private(set) var microphone: Status = .notDetermined
    private(set) var accessibility: Status = .notDetermined

    private var pollTask: Task<Void, Never>?

    var allGranted: Bool { microphone.isGranted && accessibility.isGranted }

    // MARK: - Reading

    func refresh() {
        microphone = Self.microphoneStatus()
        // `AXIsProcessTrustedWithOptions(nil)` rather than `AXIsProcessTrusted()`: the latter is
        // documented to cache within a process on some releases, which is exactly the "I granted
        // it and the app still says I did not" report this poll exists to prevent.
        accessibility = AXIsProcessTrustedWithOptions(nil) ? .granted : .denied
    }

    /// The bundle macOS is actually deciding about.
    ///
    /// Accessibility is granted per app *bundle*, and a debug build lives inside DerivedData at a
    /// path that changes with the checkout — so a second clone or a git worktree produces a second
    /// OurWhisper.app that has been granted nothing, while System Settings still shows a ticked
    /// OurWhisper. Showing this path is the difference between a five-minute fix and an hour.
    nonisolated var runningBundleURL: URL { Bundle.main.bundleURL }

    /// True when another OurWhisper.app exists elsewhere in DerivedData — the usual cause of a
    /// permission that looks granted but is not.
    nonisolated var hasOtherBuilds: Bool {
        let derived = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: derived, includingPropertiesForKeys: nil
        ) else { return false }

        let mine = runningBundleURL.standardizedFileURL
        return contents
            .filter { $0.lastPathComponent.hasPrefix("OurWhisper-") }
            .contains { candidate in
                let app = candidate.appendingPathComponent("Build/Products/Debug/OurWhisper.app")
                return FileManager.default.fileExists(atPath: app.path)
                    && app.standardizedFileURL != mine
            }
    }

    private static func microphoneStatus() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    /// Accessibility can be revoked in System Settings while we run, and the app gets no
    /// notification. A 2-second poll is cheap and is the difference between a clear warning and
    /// dictation mysteriously doing nothing.
    func beginMonitoring() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.refresh()
            }
        }
    }

    func stopMonitoring() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Requesting

    /// Shows the system microphone prompt. Only works once — after that macOS ignores it and the
    /// user has to go to Settings, which is why `openSettings` exists.
    func requestMicrophone() async {
        guard microphone == .notDetermined else {
            openSettings(for: .microphone)
            return
        }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
    }

    /// There is no "request" for Accessibility. This prompts macOS to show its one-time dialog
    /// and open the settings pane; the user still has to flip the switch themselves.
    func requestAccessibility() {
        // The literal rather than `kAXTrustedCheckOptionPrompt`: that symbol is a C global `var`,
        // which Swift 6 rejects as shared mutable state. Its value is fixed API.
        let options = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        refresh()
    }

    // MARK: - Settings deep links

    enum Pane {
        case microphone
        case accessibility

        var url: URL? {
            switch self {
            case .microphone:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            case .accessibility:
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            }
        }
    }

    func openSettings(for pane: Pane) {
        guard let url = pane.url else { return }
        NSWorkspace.shared.open(url)
    }
}
