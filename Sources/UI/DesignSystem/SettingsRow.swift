import SwiftUI

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
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(tint)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium))
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // The text column yields first. Without this the label's ideal width wins the
            // negotiation and the control on the right is pushed past the edge of the pane.
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(-1)

            control
                .labelsHidden()
                .controlSize(.regular)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(14)
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
