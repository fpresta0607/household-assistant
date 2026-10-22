import Observation
import SwiftUI

/// The app updates the theme on the main actor. Shared views observe the
/// theme; widgets and the share extension retain Default in their own process.
@Observable
final class ThemeSelection: @unchecked Sendable {
    static let shared = ThemeSelection()
    var theme = AppTheme.default

    func palette(for scheme: ColorScheme) -> ThemeColors? {
        theme.colors(isDark: scheme == .dark)
    }
}

extension Color {
    init(themeRGB value: UInt32) {
        self.init(.sRGB, red: Double((value >> 16) & 255) / 255,
                  green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }
}
