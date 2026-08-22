import SwiftUI

/// The rounded-square tinted glyph used for every sidebar row.
struct SectionIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [tint.opacity(0.95), tint.opacity(0.75)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: tint.opacity(0.25), radius: 1, y: 0.5)
    }
}
