import Observation
import SwiftUI

/// What the floating pill is showing. Kept separate from `AppState` so the overlay can update at
/// display rate without invalidating the main window's view tree.
@MainActor
@Observable
final class PillModel {
    enum Phase: Equatable {
        case listening
        case transcribing
        case formatting
        case success(String)
        case failure(String)
    }

    var phase: Phase = .listening

    /// Bar heights, 0...1, newest on the right. Fixed count so the layout never reflows.
    private(set) var bars: [Double] = Array(repeating: 0.08, count: PillModel.barCount)

    static let barCount = 5

    /// Pushes one loudness sample. Called ~30 times a second while recording.
    func push(level: Float) {
        let value = Double(max(0.08, min(1, level)))
        var next = bars
        next.removeFirst()
        next.append(value)
        bars = next
    }

    func reset() {
        bars = Array(repeating: 0.08, count: Self.barCount)
        phase = .listening
    }
}
