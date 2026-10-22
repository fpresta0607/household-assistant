// Bubbles and floating glass share one preset rim in each scheme. Default preserves
// the original soft rainbow in Light and gold glass in Dark.
import SwiftUI

struct RimLook: Equatable {
    var theme: AppTheme = .default

    func bubble(isDark: Bool) -> RimPaint {
        if let palette = theme.colors(isDark: isDark) {
            return RimPaint(colors: palette.rim.map { Color(themeRGB: $0) }, angle: .zero, opacity: 1)
        }
        return RimPaint(colors: Palette.rimColors(rainbow: RimStyle.standard.rainbow(isDark: isDark)), angle: .zero, opacity: 1)
    }

    func glass(isDark: Bool) -> RimPaint {
        if let palette = theme.colors(isDark: isDark) {
            return RimPaint(colors: palette.rim.map { Color(themeRGB: $0) }, angle: .degrees(200), opacity: 1)
        }
        return isDark
            ? RimPaint(colors: Palette.rimGold, angle: .zero, opacity: 0.7)
            : RimPaint(colors: Palette.sheenColors, angle: .degrees(200), opacity: RimStyle.standard.light)
    }
}
