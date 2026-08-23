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
        // The layout below makes the same decision `ViewThatFits` used to: side by side while the
        // label still has room, stacked when it does not.
        SettingsRowLayout {
            icon
            label
            sizedControl
        }
        .padding(14)
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

/// Icon, label and control on one line — or the control on its own line when the label would be
/// squeezed below `settingsRowLabelWidth`.
///
/// This was a `ViewThatFits` with both arrangements written out, which is the obvious way to say
/// it and cost far too much: `ViewThatFits` builds *every* candidate, so each row built two copies
/// of its control, and a `Picker` is an expensive thing to build. A settings page is one SwiftUI
/// view, so flipping any switch on it re-renders every row — the Configuration screen spent about
/// 80 ms of the main thread on each change and animated at roughly five frames a second.
/// Measuring each subview once and placing it costs a tenth of that.
private struct SettingsRowLayout: Layout {
    private static let spacing: CGFloat = 12
    private static let stackedSpacing: CGFloat = 10
    /// Indented to the text column, so a stacked control reads as belonging to the row above it
    /// rather than starting a new one.
    private static let stackedIndent: CGFloat = 36

    /// One subview, measured.
    struct Measured {
        var size: CGSize
        var baseline: CGFloat
        var proposal: ProposedViewSize
    }

    struct Plan {
        var isStacked: Bool
        var icon: Measured
        var label: Measured
        /// Absent for the rows that are a sentence and nothing else — an `EmptyView` control
        /// contributes no subview at all, and indexing past it is a crash.
        var control: Measured?
        var baseline: CGFloat
        var lineHeight: CGFloat
        var size: CGSize
    }

    /// `sizeThatFits` and `placeSubviews` are called in pairs with the same proposal, so the
    /// second one has no reason to measure everything again.
    struct Cache {
        var width: CGFloat?
        var plan: Plan?
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        plan(for: proposal, subviews: subviews, cache: &cache).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let plan = plan(for: proposal, subviews: subviews, cache: &cache)
        let baseline = bounds.minY + plan.baseline

        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: baseline - plan.icon.baseline),
            proposal: plan.icon.proposal
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX + plan.icon.size.width + Self.spacing, y: baseline - plan.label.baseline),
            proposal: plan.label.proposal
        )

        guard let control = plan.control else { return }
        if plan.isStacked {
            subviews[2].place(
                at: CGPoint(x: bounds.minX + Self.stackedIndent, y: bounds.minY + plan.lineHeight + Self.stackedSpacing),
                proposal: control.proposal
            )
        } else {
            subviews[2].place(
                at: CGPoint(x: bounds.maxX - control.size.width, y: baseline - control.baseline),
                proposal: control.proposal
            )
        }
    }

    /// Everything is measured against an unspecified proposal except the label, which is the one
    /// subview whose height depends on the width it is given.
    private func plan(for proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> Plan {
        let available = proposal.width ?? .infinity
        if let plan = cache.plan, cache.width == available { return plan }

        let icon = measure(subviews[0], proposal: .unspecified)
        let control = subviews.count > 2 ? measure(subviews[2], proposal: .unspecified) : nil

        let besideWidth = available - icon.size.width - (control?.size.width ?? 0) - Self.spacing * 2
        let isStacked = control != nil && available.isFinite && besideWidth < settingsRowLabelWidth

        let labelWidth = isStacked
            ? max(0, available - icon.size.width - Self.spacing)
            : max(settingsRowLabelWidth, besideWidth)
        let label = measure(subviews[1], proposal: ProposedViewSize(width: labelWidth, height: nil))

        // The three sit on a shared first baseline, exactly as the `HStack` had them. A stacked
        // control is on its own line and takes no part in it.
        let onTheLine = isStacked ? [icon, label] : [icon, label, control].compactMap { $0 }
        let baseline = onTheLine.map(\.baseline).max() ?? 0
        let lineHeight = baseline + (onTheLine.map { $0.size.height - $0.baseline }.max() ?? 0)

        let width = available.isFinite
            ? available
            : icon.size.width + label.size.width + (control?.size.width ?? 0) + Self.spacing * 2
        let plan = Plan(
            isStacked: isStacked,
            icon: icon,
            label: label,
            control: control,
            baseline: baseline,
            lineHeight: lineHeight,
            size: CGSize(
                width: width,
                height: isStacked ? lineHeight + Self.stackedSpacing + (control?.size.height ?? 0) : lineHeight
            )
        )

        cache.width = available
        cache.plan = plan
        return plan
    }

    /// One measurement, not two. `dimensions(in:)` already carries the size the subview would
    /// take, so asking `sizeThatFits` for the same proposal measures everything a second time —
    /// which made this the single most expensive thing on the main thread while a settings screen
    /// was being built.
    private func measure(_ subview: LayoutSubviews.Element, proposal: ProposedViewSize) -> Measured {
        let dimensions = subview.dimensions(in: proposal)
        return Measured(
            size: CGSize(width: dimensions.width, height: dimensions.height),
            baseline: dimensions[.firstTextBaseline],
            proposal: proposal
        )
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
            // Lazy, so opening a screen builds only the sections that are actually on screen.
            // A settings page is a dozen sections of pickers and switches, and a `Picker` is
            // expensive to build; building all of them up front is what made switching sidebar
            // rows take a quarter of a second before anything appeared.
            LazyVStack(alignment: .leading, spacing: 22) {
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
