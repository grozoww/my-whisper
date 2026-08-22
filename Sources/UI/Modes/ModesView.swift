import SwiftUI

/// Modes: the list on the left, the editor on the right.
struct ModesView: View {
    @Environment(AppState.self) private var appState
    @State private var selection: UUID?

    var body: some View {
        // A plain HStack with an explicit width, not an HSplitView. HSplitView sizes each pane to
        // its content's ideal width, and the editor's ideal width is wider than the window — which
        // pushed the right-hand controls off the edge of the screen.
        HStack(spacing: 0) {
            list
                .frame(width: 220)
            Divider()
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Selecting eagerly rather than in `onAppear`: the first frame would otherwise render
        // "No mode selected" over a list that plainly has modes in it.
        .task { selection = selection ?? appState.modes.modes.first?.id }
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(appState.modes.modes, selection: $selection) { mode in
                // Explicit HStack for the same reason as the main sidebar: `Label`'s icon lands
                // in the list's icon gutter, which the sidebar style clips.
                HStack(spacing: 8) {
                    SectionIcon(symbol: mode.symbol, tint: mode.tint.color, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(mode.name).font(.system(size: 13, weight: .medium))
                        if !mode.appBundleIDs.isEmpty {
                            Text("\(mode.appBundleIDs.count) app\(mode.appBundleIDs.count == 1 ? "" : "s")")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .tag(mode.id)
            }
            .listStyle(.sidebar)

            Divider()

            HStack(spacing: 6) {
                Button {
                    selection = appState.modes.add().id
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a mode")

                Button {
                    guard let selection else { return }
                    appState.modes.delete(selection)
                    self.selection = appState.modes.modes.first?.id
                } label: {
                    Image(systemName: "minus")
                }
                .help("Delete the selected mode")
                .disabled(selectedMode.map(\.isBuiltIn) ?? true)

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let mode = selectedMode {
            ModeEditor(mode: mode)
                .id(mode.id)
        } else {
            EmptyStateView(
                symbol: "sparkles",
                title: "No mode selected",
                message: "Pick a mode on the left, or add one."
            )
        }
    }

    private var selectedMode: Mode? {
        appState.modes.modes.first { $0.id == selection }
    }
}

// MARK: - Editor

private struct ModeEditor: View {
    @Environment(AppState.self) private var appState

    /// Edited locally and written back on change. Binding straight into the store would rewrite
    /// the JSON file on every keystroke in the prompt field.
    @State private var draft: Mode

    init(mode: Mode) {
        _draft = State(initialValue: mode)
    }

    var body: some View {
        SettingsPage {
            SettingsSection(title: "Mode") {
                SettingsRow(symbol: "textformat", title: "Name") {
                    TextField("Name", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 110, idealWidth: 200, maxWidth: 200)
                }
                RowDivider()
                SettingsRow(symbol: "paintpalette", title: "Colour") {
                    Picker("Colour", selection: $draft.tint) {
                        ForEach(AccentTint.allCases) { tint in
                            Text(tint.title).tag(tint)
                        }
                    }
                    .frame(minWidth: 110, idealWidth: 140, maxWidth: 140)
                }
                RowDivider()
                SettingsRow(symbol: "star", title: "Symbol", detail: "Any SF Symbol name.") {
                    TextField("Symbol", text: $draft.symbol)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 110, idealWidth: 200, maxWidth: 200)
                }
            }

            SettingsSection(
                title: "Cleanup rules",
                subtitle: "These run on every dictation, instantly, with no model involved."
            ) {
                toggle("Remove filler words", "\"um\", \"uh\", and the local equivalents.", "scissors", $draft.cleanup.removeFillers)
                RowDivider()
                toggle("Resolve self-corrections", "\"send it Tuesday, no, Wednesday\" becomes \"send it Wednesday\".", "arrow.uturn.backward", $draft.cleanup.resolveSelfCorrections)
                RowDivider()
                toggle("Spoken punctuation", "Saying \"comma\" types a comma.", "text.quote", $draft.cleanup.spokenPunctuation)
                RowDivider()
                toggle("Sentence case", "Capitalise the first word of each sentence. Never lowercases anything.", "textformat.abc", $draft.cleanup.sentenceCase)
                RowDivider()
                toggle("Apply vocabulary", "Use the spellings from the Vocabulary screen.", "book", $draft.cleanup.applyVocabulary)
                RowDivider()
                toggle("Tidy whitespace", "Collapse double spaces and fix spacing around punctuation.", "space", $draft.cleanup.tidyWhitespace)
            }

            SettingsSection(
                title: "Model instructions",
                subtitle: appState.onDeviceRefiner.availability.isAvailable
                    ? "Used when \"Clean up with the on-device model\" is on in Configuration. Leave empty to skip the model for this mode."
                    : "The on-device model is not available on this Mac, so this is not used right now. \(appState.onDeviceRefiner.availability.explanation)"
            ) {
                TextEditor(text: $draft.instructions)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 130)
                    .padding(10)
                    .scrollContentBackground(.hidden)

                RowDivider()

                toggle(
                    "Use the clipboard as context",
                    "Shows the model what you have copied, so it spells the names and terms in it the same way. It is never pasted, it never leaves the Mac, and a password copied from a password manager is skipped.",
                    "doc.on.clipboard",
                    $draft.usesClipboardContext
                )
            }

            SettingsSection(
                title: "Switch to this mode in",
                subtitle: "Bundle identifiers, one per line. When \"Switch modes by app\" is on, focusing one of these picks this mode."
            ) {
                TextEditor(text: bundleIDsText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 90)
                    .padding(10)
                    .scrollContentBackground(.hidden)

                RowDivider()

                SettingsRow(
                    symbol: "questionmark.circle",
                    title: "Find an app's identifier",
                    detail: "Terminal: osascript -e 'id of app \"Slack\"'"
                ) {
                    EmptyView()
                }
            }

            if draft.isBuiltIn {
                SettingsSection(title: "Built-in mode") {
                    SettingsRow(
                        symbol: "arrow.counterclockwise",
                        title: "Reset to how it shipped",
                        detail: "Built-in modes cannot be deleted, only reset."
                    ) {
                        Button("Reset") {
                            appState.modes.resetToShipped(draft.id)
                            if let restored = appState.modes.modes.first(where: { $0.id == draft.id }) {
                                draft = restored
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .onChange(of: draft) { _, newValue in
            appState.modes.update(newValue)
        }
    }

    private var bundleIDsText: Binding<String> {
        Binding(
            get: { draft.appBundleIDs.joined(separator: "\n") },
            set: { text in
                draft.appBundleIDs = text
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private func toggle(_ title: String, _ detail: String, _ symbol: String, _ value: Binding<Bool>) -> some View {
        SettingsRow(symbol: symbol, title: title, detail: detail) {
            Toggle("", isOn: value).toggleStyle(.switch)
        }
    }
}
