import AppKit
import Foundation

/// The little sounds that tell you recording started, stopped, or failed.
///
/// These matter more than they look. The hotkey is modifier-only and the pill sits at the bottom
/// of the screen — if you are looking at what you are typing, a sound is the only confirmation
/// that the app heard the press at all. Nothing here is louder than the system alert volume, and
/// the whole thing is one switch away from silent.
enum FeedbackSound: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case pop = "Pop"
    case tink = "Tink"
    case morse = "Morse"
    case submarine = "Submarine"
    case basso = "Basso"
    case funk = "Funk"
    case blow = "Blow"

    var id: String { rawValue }

    var title: String {
        self == .none ? "Silent" : rawValue
    }

    /// System sounds rather than bundled audio files: they are already tuned to the user's alert
    /// volume, already familiar, and add nothing to the app's download size.
    var sound: NSSound? {
        guard self != .none else { return nil }
        return NSSound(named: NSSound.Name(rawValue))
    }
}

@MainActor
final class SoundPlayer {
    /// Held so a sound is not deallocated mid-play, which cuts it off.
    private var playing: [NSSound] = []

    func play(_ sound: FeedbackSound, volume: Double) {
        guard let nsSound = sound.sound else { return }
        nsSound.volume = Float(max(0, min(1, volume)))

        // A fresh copy per play. Re-triggering the same `NSSound` while it is still sounding
        // restarts it instead of overlapping, which turns rapid start/stop into silence.
        guard let copy = nsSound.copy() as? NSSound else { return }
        copy.volume = nsSound.volume
        playing.append(copy)
        copy.play()

        // Sounds are short; this just stops the array growing for the lifetime of the app.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.playing.removeAll { !$0.isPlaying }
        }
    }
}
