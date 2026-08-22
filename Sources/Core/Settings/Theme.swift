import AppKit
import SwiftUI

/// Light, dark, or whatever the system is doing.
///
/// Applied by setting `NSApp.appearance` rather than SwiftUI's `preferredColorScheme`, because the
/// pill is an AppKit panel and the menu bar glyph is neither — a SwiftUI-only override would leave
/// both of them on the system appearance and the app looking half-themed.
enum Theme: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    func apply() {
        NSApp.appearance = appearance
    }
}

/// The app's accent colour. Kept separate from `Theme` because people who want a dark app do not
/// necessarily want a different accent, and vice versa.
enum AccentTint: String, Codable, CaseIterable, Identifiable, Sendable {
    case orange
    case blue
    case purple
    case green
    case graphite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .orange: "Orange"
        case .blue: "Blue"
        case .purple: "Purple"
        case .green: "Green"
        case .graphite: "Graphite"
        }
    }

    var color: Color {
        switch self {
        case .orange: .orange
        case .blue: .blue
        case .purple: .purple
        case .green: .green
        case .graphite: Color(nsColor: .darkGray)
        }
    }
}
