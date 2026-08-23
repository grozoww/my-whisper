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
    private var activationObserver: (any NSObjectProtocol)?

    var allGranted: Bool { microphone.isGranted && accessibility.isGranted }

    // MARK: - Reading

    func refresh() {
        set(microphone: Self.microphoneStatus())
        refreshAccessibility()
    }

    /// The cheap half, and the only one worth asking for twice a second.
    ///
    /// `AXIsProcessTrustedWithOptions(nil)` rather than `AXIsProcessTrusted()`: the latter is
    /// documented to cache within a process on some releases, which is exactly the "I granted it
    /// and the app still says I did not" report this poll exists to prevent.
    private func refreshAccessibility() {
        let granted: Status = AXIsProcessTrustedWithOptions(nil) ? .granted : .denied
        // `@Observable` publishes a write whether or not the value changed, so writing the same
        // answer every two seconds would invalidate every view watching this — for ever.
        if accessibility != granted { accessibility = granted }
    }

    private func set(microphone status: Status) {
        if microphone != status { microphone = status }
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

    /// Screenshot mode only. `scripts/screenshots.sh` builds a bundle that has been granted
    /// nothing, and a README picture of the first-launch checklist says nothing about what the app
    /// does. Nothing else calls this, and it never touches what macOS actually believes.
    func poseAsGranted() {
        microphone = .granted
        accessibility = .granted
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
    ///
    /// The microphone is deliberately *not* in the poll. `AVCaptureDevice.authorizationStatus` is
    /// around 13 ms on the main thread, so asking every two seconds forever is a periodic stutter
    /// in a menu bar app that is meant to be invisible. It can only change in System Settings, and
    /// coming back from System Settings means activating this app — so that is when it is re-read.
    func beginMonitoring() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.refreshAccessibility()
            }
        }

        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.set(microphone: Self.microphoneStatus()) }
        }
    }

    func stopMonitoring() {
        pollTask?.cancel()
        pollTask = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
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

    /// The command that clears this app's entry from the permission database.
    ///
    /// Exposed as a value rather than only run, so a test can check what would be run — actually
    /// running it would reset the Accessibility permission of whoever ran the suite.
    nonisolated var accessibilityResetCommand: (path: String, arguments: [String])? {
        guard let identifier = Bundle.main.bundleIdentifier, !identifier.isEmpty else { return nil }
        return ("/usr/bin/tccutil", ["reset", "Accessibility", identifier])
    }

    /// Forgets this app's Accessibility entry, then asks for it again.
    ///
    /// System Settings lists an app by *name*, but macOS records the grant against a code signing
    /// requirement. An entry granted to a differently signed OurWhisper — an older release, or a
    /// build from another checkout — therefore sits in the list looking ticked while applying to
    /// nothing, and unticking and re-ticking it does not reliably replace the stale record.
    /// Removing it does. This is the `-` button in System Settings, minus having to know that is
    /// the fix.
    ///
    /// Only offered while Accessibility is denied, so there is never a working grant to destroy.
    func resetAccessibilityGrant() async {
        guard let command = accessibilityResetCommand else { return }

        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.path)
            process.arguments = command.arguments
            // A failure is not worth interrupting anyone over: the row stays on screen, and the
            // instructions printed beside the button are still the way through by hand.
            try? process.run()
            process.waitUntilExit()
        }.value

        // Removing the entry is also what makes macOS willing to show its one-time prompt again,
        // which is why the request comes after the reset rather than instead of it.
        requestAccessibility()
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
