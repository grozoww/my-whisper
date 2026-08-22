import SwiftUI

/// The sidebar destinations, in display order and grouped the way they appear in the window.
enum NavigationSection: String, CaseIterable, Identifiable, Hashable {
    case home
    case modes
    case vocabulary
    case configuration
    case sound
    case modelsLibrary
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .modes: "Modes"
        case .vocabulary: "Vocabulary"
        case .configuration: "Configuration"
        case .sound: "Sound"
        case .modelsLibrary: "Models library"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .modes: "sparkles"
        case .vocabulary: "book.fill"
        case .configuration: "gearshape.fill"
        case .sound: "speaker.wave.2.fill"
        case .modelsLibrary: "books.vertical.fill"
        case .history: "clock.arrow.circlepath"
        }
    }

    var tint: Color {
        switch self {
        case .home: .orange
        case .modes, .vocabulary: .blue
        case .configuration, .sound, .modelsLibrary: Color(nsColor: .darkGray)
        case .history: .purple
        }
    }

    /// Opens the app on a given screen: `OURWHISPER_SECTION=modes open -a OurWhisper`.
    ///
    /// The window is only reachable by clicking a menu bar icon, which makes every screen but Home
    /// awkward to inspect from a script or a debugger — and impossible for anything automated.
    /// Same reasoning as `OURWHISPER_SELFTEST`.
    static var requested: NavigationSection? {
        ProcessInfo.processInfo.environment["OURWHISPER_SECTION"].flatMap(NavigationSection.init(rawValue:))
    }

    /// Sidebar groups, separated by spacing in the list.
    static let groups: [[NavigationSection]] = [
        [.home, .modes, .vocabulary],
        [.configuration, .sound, .modelsLibrary],
        [.history],
    ]
}
