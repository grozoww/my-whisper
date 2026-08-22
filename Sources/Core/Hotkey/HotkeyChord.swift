import CoreGraphics
import Foundation

/// A hotkey: either a key with modifiers, or modifiers alone.
///
/// Modifier-only chords matter here. The reference app's default is the "hyper" combination
/// (⌥⌘⌃⇧ with no key), which is close to impossible to press by accident and does not collide
/// with any application shortcut.
struct HotkeyChord: Codable, Equatable, Sendable {
    /// Virtual key code, or nil for a modifier-only chord.
    var keyCode: CGKeyCode?
    /// Raw `CGEventFlags` bits, stored as a number so the chord is `Codable`.
    var modifierBits: UInt64

    var modifiers: CGEventFlags { CGEventFlags(rawValue: modifierBits) }
    var isModifierOnly: Bool { keyCode == nil }

    init(keyCode: CGKeyCode? = nil, modifiers: CGEventFlags) {
        self.keyCode = keyCode
        self.modifierBits = modifiers.rawValue & Self.significantFlags.rawValue
    }

    /// Everything else in `CGEventFlags` — caps lock, numeric pad, the "non-coalesced" bit — is
    /// noise for shortcut purposes and would break equality checks if compared.
    static let significantFlags: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]

    func isSatisfied(by flags: CGEventFlags) -> Bool {
        flags.intersection(Self.significantFlags) == modifiers
    }

    /// The reference app's default: hold all four standard modifiers.
    static let hyper = HotkeyChord(modifiers: [.maskCommand, .maskAlternate, .maskControl, .maskShift])

    /// Keycap glyphs, in the order macOS displays them.
    var displayGlyphs: [String] {
        var glyphs: [String] = []
        if modifiers.contains(.maskControl) { glyphs.append("⌃") }
        if modifiers.contains(.maskAlternate) { glyphs.append("⌥") }
        if modifiers.contains(.maskShift) { glyphs.append("⇧") }
        if modifiers.contains(.maskCommand) { glyphs.append("⌘") }
        if modifiers.contains(.maskSecondaryFn) { glyphs.append("fn") }
        if let keyCode { glyphs.append(Self.keyName(keyCode)) }
        return glyphs
    }

    private static func keyName(_ code: CGKeyCode) -> String {
        switch code {
        case 49: "space"
        case 53: "esc"
        case 36: "return"
        case 48: "tab"
        default: "key \(code)"
        }
    }
}

enum HotkeyMode: String, Codable, Sendable {
    /// Press once to start, press again to stop.
    case toggle
    /// Hold to record, release to finish.
    case pushToTalk
}
