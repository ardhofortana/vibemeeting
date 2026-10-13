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

    /// The main accent: buttons, selection, highlights.
    static let accent = blue
    /// The "Them" speaker name: between the logo's cyan and blue.
    static let sky = dynamic(light: (0, 113, 227), dark: (110, 176, 255))
    /// The reply style menu in the overlay header.
    static let lavender = dynamic(light: (88, 80, 236), dark: (172, 180, 255))
    /// Text on the soft gradient (the Reply button).
    static let ink = Color(red: 0.09, green: 0.15, blue: 0.40)

    /// The logo's gradient.
    static func gradient(startPoint: UnitPoint = .leading, endPoint: UnitPoint = .trailing) -> LinearGradient {
        LinearGradient(colors: [cyan, blue, violet, magenta], startPoint: startPoint, endPoint: endPoint)
    }

    /// Pale tints of the gradient for the main Reply button, so its dark label stays readable.
    static func softGradient(startPoint: UnitPoint = .leading, endPoint: UnitPoint = .trailing) -> LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 165 / 255, green: 230 / 255, blue: 255 / 255),
                Color(red: 192 / 255, green: 200 / 255, blue: 255 / 255),
                Color(red: 232 / 255, green: 188 / 255, blue: 252 / 255),
            ],
            startPoint: startPoint,
            endPoint: endPoint
        )
    }

    /// Lighter on dark backgrounds, so accents stay readable in Dark Mode.
    private static func dynamic(light: (Int, Int, Int), dark: (Int, Int, Int)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
        })
    }
}
