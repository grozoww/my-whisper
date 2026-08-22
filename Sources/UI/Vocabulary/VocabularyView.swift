import SwiftUI

/// Words the speech model gets wrong, and what they should be.
struct VocabularyView: View {
    @Environment(AppState.self) private var appState
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if appState.vocabulary.entries.isEmpty {
                EmptyStateView(
                    symbol: "book.closed",
                    title: "No vocabulary yet",
                    message: "Add the names, product names and jargon the speech model keeps getting wrong. Each entry replaces what the model produces with the spelling you want — exactly, every time.",
                    actionTitle: "Add the first entry",
                    action: { selection = appState.vocabulary.add(term: "OurWhisper", soundsLike: ["our whisper"]).id }
                )
                .frame(maxHeight: .infinity)
            } else {
                table
            }

            Divider()
            footer
        }
    }

    private var table: some View {
        Table(appState.vocabulary.entries, selection: $selection) {
            TableColumn("Use this spelling") { entry in
                TextField("Term", text: binding(for: entry, keyPath: \.term))
                    .textFieldStyle(.plain)
            }
            .width(min: 140, ideal: 200)

            TableColumn("When you hear") { entry in
                TextField(
                    "comma separated",
                    text: Binding(
                        get: { entry.soundsLike.joined(separator: ", ") },
                        set: { text in
                            var updated = entry
                            updated.soundsLike = text
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                            appState.vocabulary.update(updated)
                        }
                    )
                )
                .textFieldStyle(.plain)
            }
            .width(min: 180, ideal: 280)

            TableColumn("On") { entry in
                Toggle("", isOn: binding(for: entry, keyPath: \.isEnabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            .width(44)
        }
        .tableStyle(.inset)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                selection = appState.vocabulary.add().id
            } label: {
                Image(systemName: "plus")
            }
            .help("Add an entry")

            Button {
                guard let selection else { return }
                appState.vocabulary.delete(selection)
                self.selection = nil
            } label: {
                Image(systemName: "minus")
            }
            .help("Delete the selected entry")
            .disabled(selection == nil)

            Spacer()

            Text("Matched whole-word and case-insensitively, in any script.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(8)
    }

    /// Writes each edit straight back to the store. Vocabulary rows are one short field each, so
    /// there is no draft state worth the complication — unlike the mode editor's prompt box.
    private func binding<Value>(
        for entry: VocabularyEntry,
        keyPath: WritableKeyPath<VocabularyEntry, Value>
    ) -> Binding<Value> {
        Binding(
            get: { entry[keyPath: keyPath] },
            set: { newValue in
                var updated = entry
                updated[keyPath: keyPath] = newValue
                appState.vocabulary.update(updated)
            }
        )
    }
}
