import AppKit
import ApplicationServices
import OSLog

/// Puts transcribed text into whatever text field had focus when recording started.
///
/// Order of operations is the whole game here. The target is captured *before* any UI appears,
/// because showing a window — even a non-activating one — can change what `frontmostApplication`
/// reports. Paste then goes through the clipboard, because that is the only method every app
/// honours; direct Accessibility insertion is tried as a fallback for the apps that block it.
///
/// Going through the clipboard is also why "nowhere to paste" is a case at all. A frontmost app
/// with no caret in it swallows the ⌘V and says nothing, and the restore that follows puts the
/// user's old clipboard back over the text — so a dictation into a Finder window used to vanish
/// with a tick and the word "Finder" on the pill. `clipboardOnly` is that case handled.
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

    /// Bundle identifier of the app that had focus. Used to pick a mode automatically, which is
    /// why it is read at capture time along with everything else rather than looked up later.
    var targetBundleID: String? { capturedTarget?.bundleIdentifier }

    // MARK: - Injection

    /// Puts the text where it belongs and says how it got there.
    ///
    /// `keepWhenNothingFocused` is `DictationSettings.keepOnClipboardWhenNothingFocused`, and it
    /// only ever decides whether the *restore* happens. The keystroke is posted either way.
    @discardableResult
    func inject(_ text: String, keepWhenNothingFocused: Bool) async throws -> Method {
        guard !text.isEmpty else { return .paste }

        guard let target = capturedTarget else {
            // Nothing was frontmost at all, so there is no app to activate and no field to reach.
            // The clipboard is the only place left that is better than dropping the text.
            guard keepWhenNothingFocused else { throw InjectionError.noTarget }
            writeToClipboard(text)
            return .clipboardOnly
        }

        // The user may have switched apps while we transcribed. Put their original app back in
        // front, otherwise the text lands somewhere they were not looking.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier,
           let app = NSRunningApplication(processIdentifier: target.processIdentifier) {
            app.activate()
            try? await Task.sleep(for: .milliseconds(60))
        }

        // Asked before the clipboard is touched, so the answer is about the field the user was in
        // rather than about anything the paste left behind.
        let nowhereToPaste = keepWhenNothingFocused && !focusedElementAcceptsText()

        let saved = PasteboardSnapshot.capture()
        writeToClipboard(text)

        if postPasteKeystroke() {
            // The keystroke went out regardless — `focusedElementAcceptsText` is not trusted
            // enough to cancel a paste. What changes is that the old clipboard does not come back
            // over the top of text that had nowhere to land.
            guard !nowhereToPaste else {
                log.debug("Nothing focused took the text; left on the clipboard")
                return .clipboardOnly
            }

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

    private func writeToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Whether the element that had focus can take text.
    ///
    /// Trusted in one direction only, and the asymmetry is deliberate. A `false` is acted on —
    /// it is what a Finder window, a PDF in Preview, or a desktop with nothing focused looks
    /// like, and being wrong costs the user a clipboard the app did not put back. A `false` must
    /// never *stop* the ⌘V: Chromium and Electron hand out one `AXWebArea` for a whole page
    /// instead of an element per input, so gating the paste on this would break dictation in
    /// every browser and every Electron app. `AXWebArea` counts as text for the same reason —
    /// not because a page is a text field, but because a browser will not tell us which part of
    /// it has the caret.
    ///
    /// Asked here and not in `captureTarget`, which runs inside the event tap callback: a round
    /// trip to another process there is exactly the work that makes macOS switch the tap off.
    private func focusedElementAcceptsText() -> Bool {
        guard let element = capturedElement else { return false }

        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }

        // Plenty of apps decline to call the attribute settable and still accept a paste, so the
        // role gets a say before the answer is no.
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let name = role as? String
        else { return false }
        return Self.textRoles.contains(name)
    }

    /// Roles that mean a paste has somewhere to go.
    private static let textRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXWebArea",
    ]
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
