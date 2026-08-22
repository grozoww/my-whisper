import AppKit
import SwiftUI

/// Owns the floating recording overlay.
///
/// The window must never take keyboard focus. That is not a nicety: the app pastes into whatever
/// field was focused, so if the pill stole focus there would be nothing left to paste into. Hence
/// `nonactivatingPanel`, `canBecomeKey == false`, and mouse events passed straight through.
@MainActor
final class PillWindowController {
    private var panel: PillPanel?
    private let model = PillModel()
    /// The display the current pill belongs to, fixed for as long as it is up.
    private var screen: NSScreen?

    var pillModel: PillModel { model }

    func show() {
        model.reset()
        let panel = panel ?? makePanel()
        self.panel = panel
        // Chosen once, here, rather than on every re-fit: the pill belongs on the screen the user
        // started dictating on, and re-reading the pointer would make it hop displays mid-sentence
        // if they moved the mouse.
        let mouse = NSEvent.mouseLocation
        screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        reposition(panel)
        // `orderFrontRegardless` rather than `makeKeyAndOrderFront` — the latter would do exactly
        // the thing this window must never do.
        panel.orderFrontRegardless()
    }

    /// The only way the phase should be changed.
    ///
    /// Each phase has a different width — "Cleaning up" is wider than five audio bars — and a
    /// window sized to its content view is not resized by that content changing. Setting the model
    /// directly leaves the panel at the previous phase's width, which truncates the longer label
    /// and pushes the pill off centre. Re-fitting here is what keeps that from being something
    /// every call site has to remember.
    func setPhase(_ phase: PillModel.Phase) {
        model.phase = phase
        guard let panel else { return }
        reposition(panel)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Leaves the pill up briefly so the user sees the result, then dismisses it.
    func dismiss(after delay: Duration) {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            self?.hide()
        }
    }

    private func makePanel() -> PillPanel {
        let panel = PillPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false // the SwiftUI capsule draws its own, correctly shaped
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        // Follow the user across spaces and sit above full-screen apps, because dictation is used
        // inside other apps' full-screen windows more often than not.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let host = NSHostingView(rootView: PillView().environment(model))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        return panel
    }

    /// Bottom-centre of the screen picked in `show()`, so the pill appears where the user is
    /// working rather than always on the main display.
    private func reposition(_ panel: NSPanel) {
        guard let frame = (screen ?? NSScreen.main)?.visibleFrame else { return }

        // `layoutIfNeeded` alone returns the size from before the phase changed; the hosting view
        // has to be invalidated first or the panel keeps the old width.
        panel.contentView?.invalidateIntrinsicContentSize()
        panel.layoutIfNeeded()
        let margin = PillView.shadowMargin
        let size = panel.contentView?.fittingSize ?? NSSize(width: 140 + margin * 2, height: 44 + margin * 2)
        // The window is bigger than the capsule by the shadow margin on every side, so the offset
        // is measured to the capsule rather than to the window. Otherwise turning the margin up
        // would quietly push the pill further from the bottom of the screen.
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 96 - margin
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

/// A borderless panel refuses key status by default only when it is not `nonactivating`; being
/// explicit costs one line and removes any doubt.
private final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
