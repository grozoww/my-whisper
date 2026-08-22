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

    var pillModel: PillModel { model }

    func show() {
        model.reset()
        let panel = panel ?? makePanel()
        self.panel = panel
        reposition(panel)
        // `orderFrontRegardless` rather than `makeKeyAndOrderFront` — the latter would do exactly
        // the thing this window must never do.
        panel.orderFrontRegardless()
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

    /// Bottom-centre of whichever screen holds the pointer, so the pill appears where the user is
    /// working rather than always on the main display.
    private func reposition(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        panel.layoutIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 140, height: 44)
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 96
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
