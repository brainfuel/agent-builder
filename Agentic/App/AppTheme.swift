import SwiftUI

enum AppTheme {
    // Primary brand — slate blue #4C75A1
    static let brandTint = Color(red: 76.0 / 255.0, green: 117.0 / 255.0, blue: 161.0 / 255.0)

    // Canvas
    static let canvasBackground = Color(red: 0.96, green: 0.965, blue: 0.97)

    // Surfaces
    static let surfacePrimary = Color(uiColor: .systemBackground)
    static let surfaceSecondary = Color(uiColor: .secondarySystemBackground)
    static let surfaceGrouped = Color(uiColor: .systemGroupedBackground)

    // Node card accents
    static let nodeInput = Color(red: 76.0 / 255.0, green: 137.0 / 255.0, blue: 204.0 / 255.0)
    static let nodeOutput = Color(red: 64.0 / 255.0, green: 166.0 / 255.0, blue: 153.0 / 255.0)
    static let nodeAgent = Color(red: 76.0 / 255.0, green: 117.0 / 255.0, blue: 161.0 / 255.0)
    static let nodeHuman = Color(red: 82.0 / 255.0, green: 172.0 / 255.0, blue: 120.0 / 255.0)

    // Subtle border for cards
    static let cardBorder = Color.black.opacity(0.06)
    static let cardShadow = Color.black.opacity(0.06)

    // Link tones — semantic flow categorization on canvas edges.
    static let linkBlue   = Color(red: 76.0  / 255.0, green: 117.0 / 255.0, blue: 161.0 / 255.0)
    static let linkOrange = Color(red: 214.0 / 255.0, green: 142.0 / 255.0, blue: 78.0  / 255.0)
    static let linkTeal   = Color(red: 64.0  / 255.0, green: 166.0 / 255.0, blue: 153.0 / 255.0)
    static let linkGreen  = Color(red: 82.0  / 255.0, green: 172.0 / 255.0, blue: 120.0 / 255.0)
    static let linkIndigo = Color(red: 97.0  / 255.0, green: 104.0 / 255.0, blue: 180.0 / 255.0)
}
