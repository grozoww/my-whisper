import SwiftUI

struct SidebarView: View {
    @Binding var selection: NavigationSection

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(Array(NavigationSection.groups.enumerated()), id: \.offset) { index, group in
                    Section {
                        ForEach(group) { section in
                            Label {
                                Text(section.title)
                                    .font(.system(size: 14))
                            } icon: {
                                SectionIcon(symbol: section.symbol, tint: section.tint)
                            }
                            .padding(.vertical, 2)
                            .tag(section)
                        }
                    }
                    .listSectionSeparator(.hidden)
                    // Groups are separated by whitespace, not a divider, matching the reference.
                    .padding(.top, index == 0 ? 0 : 10)
                }
            }
            .listStyle(.sidebar)

            Spacer(minLength: 0)

            SidebarFooter()
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
    }
}

private struct SidebarFooter: View {
    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return "Version \(short)"
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(version)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Link(destination: URL(string: "https://github.com/grozoww/our-whisper")!) {
                Text("OurWhisper")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.5), in: .capsule)
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}
