import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        NavigationSplitView {
            SidebarView(selection: $appState.selectedSection)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                // The reference app shows no window title — the sidebar already says where you
                // are, and the toolbar's right side is reserved for the input device.
                .toolbar(removing: .title)
                .toolbar { inputDeviceToolbar }
        }
        // Wide enough for the widest screen: the sidebar, the mode list beside it, and an editor
        // with room for a label and its control on one line. At the old 780 the mode editor was
        // squeezed until its labels broke one letter per line.
        .frame(minWidth: 880, minHeight: 560)
        .tint(appState.settings.settings.appearance.accent.color)
        .onDisappear { WindowPresenter.resignIfNoWindows() }
    }

    /// Which microphone dictation will record from, on the trailing edge of every screen.
    ///
    /// Three wrinkles. Without a title there is nothing pushing the item right, so it needs an
    /// explicit spacer. On macOS 26 every toolbar item gets a glass background by default, which
    /// reads as a button here — `sharedBackgroundVisibility(.hidden)` turns that off. And a name
    /// sitting in a corner explains nothing on its own, so it is a button to the screen that
    /// changes it, with the sentence in its tooltip.
    @ToolbarContentBuilder
    private var inputDeviceToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .primaryAction) { inputDeviceButton }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) { Spacer() }
            ToolbarItem(placement: .primaryAction) { inputDeviceButton }
        }
    }

    private var inputDeviceButton: some View {
        Button {
            appState.selectedSection = .sound
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                Text(appState.inputDeviceName)
                    .lineLimit(1)
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        // A toolbar item at `.primaryAction` sits hard against the window edge, and a plain label
        // with no button chrome around it has nothing to hold it off. This is the inset the glass
        // background would have given it.
        .padding(.trailing, 12)
        .help("Dictation records from this microphone. Click to change it in Sound.")
    }

    @ViewBuilder
    private var detail: some View {
        switch appState.selectedSection {
        case .home: HomeView()
        case .modes: ModesView()
        case .vocabulary: VocabularyView()
        case .configuration: ConfigurationView()
        case .sound: SoundView()
        case .modelsLibrary: ModelsLibraryView()
        case .history: HistoryView()
        }
    }
}
