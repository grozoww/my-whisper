import AppKit
import SwiftUI
import Testing

@testable import OurWhisper

/// Builds every screen and forces a layout pass.
///
/// A SwiftUI view that crashes on construction — a force-unwrapped binding, a `Picker` whose
/// selection type does not match its tags, an index out of range in a list — compiles perfectly
/// and fails the first time a person clicks that sidebar row. Unit tests over the stores do not
/// catch it, because none of them ever build a view.
///
/// This is deliberately shallow: it proves each screen can be constructed and laid out against
/// real stores, not that it looks right. Looking right is still a human's job.
///
/// Serialized: these build AppKit windows, and running several at once churns the shared
/// application state in ways that have nothing to do with the views under test.
@Suite("Screens render", .serialized)
@MainActor
struct ViewRenderingTests {
    /// Stores pointed at a temporary directory, so rendering a screen cannot read or write the
    /// real settings, modes, vocabulary or history of whoever runs the suite.
    private func makeState() -> (AppState, TemporaryDirectory) {
        let temp = TemporaryDirectory()
        let state = AppState(directory: temp.url)
        return (state, temp)
    }

    private func render(_ view: some View, size: CGSize = CGSize(width: 900, height: 700)) {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        // Without a window the view is never attached to a display list and SwiftUI skips most of
        // the work, which would make this test pass on views that crash in practice.
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // A programmatically created NSWindow releases itself on `close()`. ARC then releases it
        // again, which crashes the whole test process rather than failing one test.
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        window.orderOut(nil)
        window.contentView = nil
    }

    @Test("Every sidebar destination builds and lays out", arguments: NavigationSection.allCases)
    func rendersEverySection(section: NavigationSection) {
        let (state, temp) = makeState()
        state.selectedSection = section
        render(RootView().environment(state))
        _ = temp
    }

    @Test("Home renders with history present")
    func rendersHomeWithData() {
        let (state, temp) = makeState()
        state.history.record(
            HistoryEntry(
                rawText: "um hello",
                finalText: "Hello.",
                appName: "Slack",
                appBundleID: "com.tinyspeck.slackmacgap",
                modeName: "Chat",
                providerID: .parakeet,
                language: .english,
                usedModel: false,
                audioDuration: 3,
                processingTime: 0.3
            ),
            settings: HistorySettings()
        )
        state.selectedSection = .home
        render(RootView().environment(state))
        _ = temp
    }

    @Test("History renders with an entry selected")
    func rendersHistoryDetail() {
        let (state, temp) = makeState()
        for index in 0..<3 {
            state.history.record(
                HistoryEntry(
                    rawText: "raw \(index)",
                    finalText: "final \(index)",
                    appName: "Mail",
                    appBundleID: "com.apple.mail",
                    modeName: "Email",
                    providerID: .soniox,
                    language: .ukrainian,
                    usedModel: true,
                    audioDuration: 5,
                    processingTime: 1,
                    audioFileName: "\(index).wav"
                ),
                settings: HistorySettings()
            )
        }
        state.selectedSection = .history
        render(RootView().environment(state))
        _ = temp
    }

    @Test("Vocabulary renders with entries")
    func rendersVocabularyWithEntries() {
        let (state, temp) = makeState()
        state.vocabulary.add(term: "Kruhlov", soundsLike: ["Kruglov"])
        state.selectedSection = .vocabulary
        render(RootView().environment(state))
        _ = temp
    }

    @Test("Modes renders each mode's editor", arguments: 0..<Mode.builtIns.count)
    func rendersEachModeEditor(index: Int) {
        let (state, temp) = makeState()
        state.settings.settings.refinement.activeModeID = state.modes.modes[index].id
        state.selectedSection = .modes
        render(RootView().environment(state))
        _ = temp
    }

    @Test("The pill renders in every phase", arguments: [
        PillModel.Phase.listening,
        .transcribing,
        .formatting,
        .success("Slack"),
        .failure("Could not paste. The text is on your clipboard."),
    ])
    func rendersPillPhases(phase: PillModel.Phase) {
        let model = PillModel()
        model.phase = phase
        render(PillView().environment(model), size: CGSize(width: 340, height: 60))
    }

    @Test("The menu bar content builds")
    func rendersMenuBar() {
        let (state, temp) = makeState()
        render(MenuBarContent().environment(state), size: CGSize(width: 260, height: 400))
        _ = temp
    }
}
