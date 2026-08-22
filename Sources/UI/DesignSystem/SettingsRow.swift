import SwiftUI

/// How much room a `SettingsRow` label needs before its control is allowed to sit beside it.
/// Under this, the row stacks instead. The layout before this had no floor under the text column,
/// and in a narrow pane — the mode editor at the window's minimum width — "Symbol" came out as one
/// letter per line.
private let settingsRowLabelWidth: CGFloat = 150

/// The standard row inside a `Card`: icon, title, explanation, control on the right.
///
/// Every settings screen is built from this. Not for tidiness — for honesty. The layout forces
/// each control to carry a sentence saying what it does, so a switch cannot ship without an
/// explanation the way it can when each screen is laid out by hand.
struct SettingsRow<Control: View>: View {
    let symbol: String
    let title: String
    var detail: String?
    var tint: Color = .secondary
    @ViewBuilder var control: Control

    var body: some View {
        // `ViewThatFits` measures the first layout at its ideal width, which the frame below
        // pins to icon + label + control. When the pane is narrower than that, the second layout
        // wins and the control moves to a line of its own.
        ViewThatFits(in: .horizontal) {
            sideBySide
            stacked
        }
        .padding(14)
    }

    private var sideBySide: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            icon
            label
                .frame(
                    minWidth: settingsRowLabelWidth,
                    idealWidth: settingsRowLabelWidth,
                    maxWidth: .infinity,
                    alignment: .leading
                )
            sizedControl
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                icon
                label
                Spacer(minLength: 0)
            }
            // Indented to the text column, so the control reads as belonging to the row above it
            // rather than starting a new one.
            sizedControl
                .padding(.leading, 36)
        }
    }

    private var icon: some View {
        Image(systemName: symbol)
            .font(.system(size: 16))
            .foregroundStyle(tint)
            .frame(width: 24, alignment: .center)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 14, weight: .medium))
            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sizedControl: some View {
        control
            .labelsHidden()
            .controlSize(.regular)
            .fixedSize(horizontal: true, vertical: false)
    }
}

extension SettingsRow where Control == EmptyView {
    init(symbol: String, title: String, detail: String? = nil, tint: Color = .secondary) {
        self.init(symbol: symbol, title: title, detail: detail, tint: tint) { EmptyView() }
    }
}

/// A divider that lines up with the row text rather than the card edge, matching how macOS draws
/// grouped lists.
struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 52)
    }
}

/// Title, optional subtitle, and a `Card` of rows. The unit every settings screen is a stack of.
struct SettingsSection<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 17, weight: .semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Card { content }
        }
    }
}

/// The page shell: a scrolling column, capped at a readable width and centred.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Shown when a list is empty, in place of a blank pane.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }
}

/// Bytes as something a person reads. `.file` style so 600 MB shows as "600 MB", which is what the
/// download actually is, rather than the 572 MiB a binary count would report.
func formattedBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useMB, .useGB, .useKB]
    return formatter.string(fromByteCount: bytes)
}
