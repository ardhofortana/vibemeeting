import AppKit
import SwiftUI

/// VibeMeeting's colors, taken from the logo's gradient (cyan → blue → violet →
/// magenta). Used as accents only: primary actions, selection and highlights,
/// live level meters, and a thin line along the top of the overlay. Status
/// colors (listening, warnings, errors) stay semantic.
enum Brand {
    static let cyan = dynamic(light: (34, 216, 254), dark: (84, 226, 255))
    static let blue = dynamic(light: (10, 92, 255), dark: (77, 141, 255))
    static let violet = dynamic(light: (106, 53, 252), dark: (146, 108, 255))
    static let magenta = dynamic(light: (208, 75, 246), dark: (224, 122, 250))

    /// The main accent: buttons, selection, the "Them" label.
    static let accent = blue

    /// The logo's gradient.
    static func gradient(startPoint: UnitPoint = .leading, endPoint: UnitPoint = .trailing) -> LinearGradient {
        LinearGradient(colors: [cyan, blue, violet, magenta], startPoint: startPoint, endPoint: endPoint)
    }

    /// Lighter on dark backgrounds, so accents stay readable in Dark Mode.
    private static func dynamic(light: (Int, Int, Int), dark: (Int, Int, Int)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
        })
    }
}
