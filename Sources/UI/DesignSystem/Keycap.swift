import SwiftUI

/// A single key glyph, drawn like the keycaps macOS uses in its own shortcut UI.
struct Keycap: View {
    let glyph: String

    var body: some View {
        Text(glyph)
            .font(.system(size: 12, weight: .medium))
            .frame(minWidth: 22, minHeight: 22)
            .padding(.horizontal, 4)
            .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
    }
}

struct KeycapRow: View {
    let glyphs: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(glyphs.enumerated()), id: \.offset) { _, glyph in
                Keycap(glyph: glyph)
            }
        }
    }
}
