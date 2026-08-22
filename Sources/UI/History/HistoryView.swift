import AppKit
import SwiftUI

/// Everything you have dictated, searchable, with the retention setting in plain view.
struct HistoryView: View {
    @Environment(AppState.self) private var appState

    @State private var query = ""
    @State private var selection: UUID?
    @State private var showingClearConfirmation = false

    private var results: [HistoryEntry] {
        appState.history.search(query)
    }

    var body: some View {
        VStack(spacing: 0) {
            if appState.history.entries.isEmpty {
                EmptyStateView(
                    symbol: "clock.arrow.circlepath",
                    title: "Nothing dictated yet",
                    message: "Every dictation is saved here — the raw transcript, the cleaned text, and where it went. Stored on this Mac only, and deleted on the schedule you set below."
                )
                .frame(maxHeight: .infinity)
            } else {
                HSplitView {
                    list.frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
                    detail.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Divider()
            footer
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search transcripts")
        .confirmationDialog(
            "Delete every transcript?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete everything", role: .destructive) {
                appState.history.deleteAll()
                selection = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all \(appState.history.entries.count) transcripts and any saved audio. It cannot be undone.")
        }
    }

    private var list: some View {
        List(results, selection: $selection) { entry in
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.finalText)
                    .font(.system(size: 13))
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    if let app = entry.appName {
                        Text("·")
                        Text(app)
                    }
                    if let mode = entry.modeName {
                        Text("·")
                        Text(mode)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
            .tag(entry.id)
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private var detail: some View {
        if let entry = results.first(where: { $0.id == selection }) ?? results.first {
            HistoryDetail(entry: entry)
                .id(entry.id)
        } else {
            EmptyStateView(
                symbol: "magnifyingglass",
                title: "No matches",
                message: "Nothing in your history matches “\(query)”."
            )
        }
    }

    private var footer: some View {
        @Bindable var settings = appState.settings

        return HStack(spacing: 12) {
            Picker("Keep for", selection: $settings.settings.history.retention) {
                ForEach(HistoryRetention.allCases) { retention in
                    Text(retention.title).tag(retention)
                }
            }
            .frame(width: 190)

            Toggle("Keep audio", isOn: $settings.settings.history.keepAudio)
                .toggleStyle(.checkbox)
                .help("Saves the recording alongside each transcript. Useful for comparing models; costs disk and keeps recordings of your voice around.")

            Spacer()

            Text("\(appState.history.entries.count) transcripts")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Button("Delete all…") { showingClearConfirmation = true }
                .disabled(appState.history.entries.isEmpty)
        }
        .padding(10)
        .onChange(of: appState.settings.settings.history.retention) { _, retention in
            appState.history.prune(retention: retention)
        }
    }
}

// MARK: - Detail

private struct HistoryDetail: View {
    @Environment(AppState.self) private var appState
    let entry: HistoryEntry

    var body: some View {
        SettingsPage {
            SettingsSection(title: "Pasted text") {
                SelectableText(entry.finalText)
                    .padding(14)

                RowDivider()

                SettingsRow(symbol: "doc.on.doc", title: "Copy to clipboard") {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.finalText, forType: .string)
                    }
                    .buttonStyle(.bordered)
                }
            }

            if entry.rawText != entry.finalText {
                SettingsSection(
                    title: "Before cleanup",
                    subtitle: "Straight from the speech model. When the result is wrong, this is how you tell whether the model or the cleanup is at fault."
                ) {
                    SelectableText(entry.rawText)
                        .padding(14)
                }
            }

            SettingsSection(title: "Details") {
                detailRow("Recorded", entry.date.formatted(date: .long, time: .standard), "calendar")
                RowDivider()
                detailRow("Pasted into", entry.appName ?? "Unknown", "app.badge")
                RowDivider()
                detailRow("Mode", entry.modeName ?? "None", "sparkles")
                RowDivider()
                detailRow("Engine", entry.providerID == .soniox ? "Soniox (cloud)" : "Parakeet (offline)", "cpu")
                RowDivider()
                detailRow("On-device model", entry.usedModel ? "Used" : "Not used", "wand.and.stars")
                RowDivider()
                detailRow("Language", entry.language.displayName, "globe")
                RowDivider()
                detailRow(
                    "Speed",
                    String(
                        format: "%.1fs of audio in %.2fs — %.0f× realtime",
                        entry.audioDuration,
                        entry.processingTime,
                        entry.realtimeFactor
                    ),
                    "speedometer"
                )
                RowDivider()
                detailRow("Words", "\(entry.wordCount)", "textformat.123")
            }

            if let name = entry.audioFileName {
                SettingsSection(title: "Recording") {
                    SettingsRow(symbol: "waveform", title: "Saved audio", detail: name) {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(
                                [AppDirectories.recordings.appendingPathComponent(name)]
                            )
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            SettingsSection(title: "Delete") {
                SettingsRow(
                    symbol: "trash",
                    title: "Delete this transcript",
                    detail: "Removes the entry and its audio, if any."
                ) {
                    Button("Delete", role: .destructive) { appState.history.delete(entry.id) }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private func detailRow(_ title: String, _ value: String, _ symbol: String) -> some View {
        SettingsRow(symbol: symbol, title: title) {
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

/// Read-only text the user can select and copy. A `TextEditor` would let them type into a record
/// of something that already happened, which is a lie about what the screen is.
private struct SelectableText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
