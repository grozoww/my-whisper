import AppKit
import ApplicationServices
import OSLog

/// Puts transcribed text into whatever text field had focus when recording started.
///
/// Order of operations is the whole game here. The target is captured *before* any UI appears,
/// because showing a window — even a non-activating one — can change what `frontmostApplication`
/// reports. Paste then goes through the clipboard, because that is the only method every app
/// honours; direct Accessibility insertion is tried as a fallback for the apps that block it.
@MainActor
final class TextInjector {
    enum Method: String, Sendable {
        case paste
        case accessibility
        case clipboardOnly
    }

    struct Target: Sendable {
        let processIdentifier: pid_t
        let applicationName: String
        let bundleIdentifier: String?
    }

    enum InjectionError: LocalizedError {
        case noTarget
        case allMethodsFailed

        var errorDescription: String? {
            switch self {
            case .noTarget: "No app was focused when recording started."
            case .allMethodsFailed: "Could not paste. The text is on your clipboard."
            }
        }
    }

    private let log = Logger(subsystem: "com.grozoww.ourwhisper", category: "injection")

    /// How long to wait before putting the user's clipboard back. The paste is delivered
    /// asynchronously to the target app, and restoring too early pastes the *old* clipboard.
    private static let clipboardRestoreDelay = Duration.milliseconds(220)

    private var capturedTarget: Target?
    private var capturedElement: AXUIElement?

    // MARK: - Capture

    /// Called the instant the hotkey fires, before the pill is shown.
    func captureTarget() {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            capturedTarget = nil
            capturedElement = nil
            return
        }

        capturedTarget = Target(
            processIdentifier: app.processIdentifier,
            applicationName: app.localizedName ?? "the focused app",
            bundleIdentifier: app.bundleIdentifier
        )

        // Remember the focused element too. It is only used by the fallback, but it has to be
        // read now — after we show the pill, "focused" may mean something else.
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        if status == .success, let focused {
            capturedElement = (focused as! AXUIElement)
        } else {
            capturedElement = nil
        }

        log.debug("Captured target: \(self.capturedTarget?.applicationName ?? "none", privacy: .public)")
    }

    var targetName: String? { capturedTarget?.applicationName }

    // MARK: - Injection

    @discardableResult
    func inject(_ text: String) async throws -> Method {
        guard !text.isEmpty else { return .paste }
        guard let target = capturedTarget else { throw InjectionError.noTarget }

        // The user may have switched apps while we transcribed. Put their original app back in
        // front, otherwise the text lands somewhere they were not looking.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier,
           let app = NSRunningApplication(processIdentifier: target.processIdentifier) {
            app.activate()
            try? await Task.sleep(for: .milliseconds(60))
        }

        let saved = PasteboardSnapshot.capture()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        if postPasteKeystroke() {
            // Restore in the background so the caller is not blocked on the delay.
            Task { [saved] in
                try? await Task.sleep(for: Self.clipboardRestoreDelay)
                saved.restore()
            }
            return .paste
        }

        log.warning("Synthetic paste failed; trying Accessibility insertion")
        if injectViaAccessibility(text) {
            saved.restore()
            return .accessibility
        }

        // Both failed. Leave the text on the clipboard rather than restoring — the user can still
        // paste it themselves, which is better than losing what they just said.
        log.error("All injection methods failed; text left on clipboard")
        throw InjectionError.allMethodsFailed
    }

    // MARK: - Methods

    /// Synthesizes ⌘V.
    ///
    /// `privateState` matters: with the shared session state, the event inherits whatever
    /// modifiers are physically held. During push-to-talk the user is *still holding* the hotkey
    /// modifiers, so the paste would arrive as ⌥⌘⌃⇧V and do nothing.
    private func postPasteKeystroke() -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let vKeyCode: CGKeyCode = 9
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return false }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

    /// Writes into the focused element directly. Works in standard AppKit text views and fails
    /// silently in others — combo boxes in particular accept the call and do nothing — which is
    /// why this is the fallback and not the primary path.
    private func injectViaAccessibility(_ text: String) -> Bool {
        guard let element = capturedElement else { return false }
        let status = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        return status == .success
    }
}

/// A copy of the clipboard deep enough to put back exactly what was there — every item, every
/// representation. Copying only the string would quietly destroy a copied image or file.
struct PasteboardSnapshot: Sendable {
    private let items: [[String: Data]]

    static func capture() -> PasteboardSnapshot {
        let contents = NSPasteboard.general.pasteboardItems ?? []
        let copied = contents.map { item in
            var representations: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    representations[type.rawValue] = data
                }
            }
            return representations
        }
        return PasteboardSnapshot(items: copied)
    }

    func restore() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !items.isEmpty else { return }

        let restored = items.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in representations {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
