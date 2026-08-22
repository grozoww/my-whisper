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
        .frame(minWidth: 780, minHeight: 560)
        .tint(appState.settings.settings.appearance.accent.color)
        .onDisappear { WindowPresenter.resignIfNoWindows() }
    }

    /// The input device sits on the trailing edge, as plain text.
    ///
    /// Two wrinkles. Without a title there is nothing pushing the item right, so it needs an
    /// explicit spacer. And on macOS 26 every toolbar item gets a glass background by default,
    /// which reads as a button here — `sharedBackgroundVisibility(.hidden)` turns that off.
    @ToolbarContentBuilder
    private var inputDeviceToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .primaryAction) { inputDeviceLabel }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) { Spacer() }
            ToolbarItem(placement: .primaryAction) { inputDeviceLabel }
        }
    }

    private var inputDeviceLabel: some View {
        HStack(spacing: 6) {
            Text(appState.inputDeviceName)
            Image(systemName: "laptopcomputer")
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
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
