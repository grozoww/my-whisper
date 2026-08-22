import SwiftUI

struct PillView: View {
    @Environment(PillModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
        .frame(minWidth: 108)
        .background {
            Capsule(style: .continuous)
                .fill(.black.opacity(0.82))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                }
        }
        .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
        .animation(.smooth(duration: 0.18), value: model.phase)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .listening:
            AudioBars(values: model.bars)
        case .transcribing:
            BusyLabel(text: "Transcribing", symbol: "waveform")
        case .formatting:
            BusyLabel(text: "Cleaning up", symbol: "sparkles")
        case .success(let target):
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(target).lineLimit(1)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
        case .failure(let message):
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(message).lineLimit(1)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .frame(maxWidth: 320)
        }
    }
}

private struct AudioBars: View {
    let values: [Double]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Capsule(style: .continuous)
                    .fill(.white)
                    // A floor keeps the bars visible during silence, so the pill reads as
                    // "listening" rather than "frozen".
                    .frame(width: 4, height: max(4, 26 * value))
            }
        }
        .frame(height: 26)
        .animation(.spring(response: 0.16, dampingFraction: 0.7), values: values)
    }
}

private struct BusyLabel: View {
    let text: String
    let symbol: String
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .opacity(pulsing ? 0.4 : 1)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)
            Text(text)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .onAppear { pulsing = true }
    }
}

private extension View {
    /// `animation(_:value:)` needs an `Equatable`; an array of doubles qualifies but reads badly
    /// inline, so this keeps the call site honest about animating the whole set together.
    func animation(_ animation: Animation?, values: [Double]) -> some View {
        self.animation(animation, value: values)
    }
}
