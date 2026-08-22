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

    /// Which build phase delivers this screen. Drives the placeholder copy so the app is honest
    /// about what is not built yet instead of showing an empty pane.
    var deliveredIn: String {
        switch self {
        case .home: "P0"
        case .modelsLibrary: "P2"
        case .modes, .vocabulary: "P3"
        case .configuration, .sound, .history: "P4"
        }
    }

    /// Sidebar groups, separated by spacing in the list.
    static let groups: [[NavigationSection]] = [
        [.home, .modes, .vocabulary],
        [.configuration, .sound, .modelsLibrary],
        [.history],
    ]
}
