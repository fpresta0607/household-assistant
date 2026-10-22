// Semantic colors shared by the app and its extensions. Default retains the original
// royal, gold, rainbow sheen and navy. Presets replace complete roles in both schemes.

import SwiftUI
import UIKit

enum Palette {
    // MARK: The brand

    /// The person's own words and every control.
    static let royal = Color(red: 0x23 / 255, green: 0x46 / 255, blue: 0xD8 / 255)
    static let royalDeep = Color(red: 0x1F / 255, green: 0x3F / 255, blue: 0xBF / 255)
    /// The assistants' presence: the ring round their faces and the rim of their bubbles.
    static let gold = Color(red: 0xE8 / 255, green: 0xB8 / 255, blue: 0x4A / 255)
    /// The icon's navy, which dark mode is drawn on.
    static let navyDeep = Color(red: 0x06 / 255, green: 0x1C / 255, blue: 0x4A / 255)
    static let navy = Color(red: 0x0B / 255, green: 0x2A / 255, blue: 0x6F / 255)
    static let cream = Color(red: 0xF3 / 255, green: 0xEA / 255, blue: 0xD0 / 255)
    /// The words on the light page.
    static let ink = Color(red: 0x14 / 255, green: 0x20 / 255, blue: 0x4A / 255)

    // MARK: The page

    /// Where the light page starts at the top, and the pale sky it ends in.
    static let pageWarm = Color(red: 0xFF / 255, green: 0xFA / 255, blue: 0xF3 / 255)
    static let pageSky = Color(red: 0xEE / 255, green: 0xF5 / 255, blue: 0xFF / 255)

    // MARK: The rainbow sheen

    static let sheenRose = Color(red: 1, green: 120 / 255, blue: 170 / 255)
    static let sheenAmber = Color(red: 1, green: 196 / 255, blue: 100 / 255)
    static let sheenMint = Color(red: 110 / 255, green: 222 / 255, blue: 186 / 255)
    static let sheenSky = Color(red: 100 / 255, green: 165 / 255, blue: 1)
    static let sheenViolet = Color(red: 176 / 255, green: 128 / 255, blue: 1)
    /// Every hue of the sheen once, from rose round to violet.
    static let sheenColors = [sheenRose, sheenAmber, sheenMint, sheenSky, sheenViolet]
    /// The rim on frosted glass: every hue once, round the edge. Computed rather than
    /// stored, since a gradient is not known to be safe to share between threads.
    static var sheen: AngularGradient {
        AngularGradient(colors: sheenColors + sheenColors.prefix(1), center: .center, angle: .degrees(200))
    }

    // MARK: The rim of an assistant's bubble

    /// Gold glass, the rim at the Glass end of Appearance's slider: gold, a pale gold
    /// highlight, deep gold, warm gold and dark gold.
    static let rimGold = [
        gold,
        Color(red: 0xFF / 255, green: 0xF3 / 255, blue: 0xC9 / 255),
        Color(red: 0xC9 / 255, green: 0x93 / 255, blue: 0x2A / 255),
        Color(red: 0xF6 / 255, green: 0xD2 / 255, blue: 0x7A / 255),
        Color(red: 0xB0 / 255, green: 0x7F / 255, blue: 0x12 / 255),
    ]
    /// The soft rainbow, the rim at the Rainbow end: sky blue, pink, butter, mint and
    /// lavender, one for each gold above, so the two blend stop by stop.
    static let rimRainbow = [
        Color(red: 0x7F / 255, green: 0xB2 / 255, blue: 0xFF / 255),
        Color(red: 0xF7 / 255, green: 0xA8 / 255, blue: 0xC4 / 255),
        Color(red: 0xFF / 255, green: 0xD2 / 255, blue: 0x7A / 255),
        Color(red: 0x9B / 255, green: 0xE3 / 255, blue: 0xC3 / 255),
        Color(red: 0xA9 / 255, green: 0xA2 / 255, blue: 0xFF / 255),
    ]
    /// The rim's colours `rainbow` of the way from gold glass to `colors`, the soft rainbow, stop by stop. Gold glass alone is the dark's own rim.
    static func rimColors(rainbow: Double, toward colors: [Color] = rimRainbow) -> [Color] {
        zip(rimGold, colors).map { gold, soft in
            gold.mix(with: soft, by: rainbow)
        }
    }

    /// The same rim as a gradient round the edge, for the widgets, which have no look of
    /// their own to keep it in (the app's is RimLook).
    static func rim(rainbow: Double) -> AngularGradient {
        let colors = rimColors(rainbow: rainbow)
        return AngularGradient(colors: colors + colors.prefix(1), center: .center, angle: .zero)
    }

    // MARK: What they are used for

    /// Text on the page: ink in the light, cream in the dark.
    private static let defaultText = dynamic(dark: cream, light: ink)
    /// Quieter words and glyphs, nearly as strong as the words with Increase Contrast.
    private static let defaultSecondaryText = dynamic(
        dark: cream.opacity(0.62),
        light: ink.opacity(0.62),
        increasedDark: cream.opacity(0.88),
        increasedLight: ink.opacity(0.88)
    )

    static var text: Color { themed(\.text, fallback: defaultText) }
    static var secondaryText: Color { themed(\.secondary, fallback: defaultSecondaryText) }
    static var highlight: Color { royalHighlight }

    /// Royal as a control: royal in the light, and a lighter royal in the dark, where
    /// royal itself would sink into the navy. With Increase Contrast, deeper in the light
    /// and paler in the dark.
    private static let defaultRoyalHighlight = dynamic(
        dark: Color(red: 0x5B / 255, green: 0x7B / 255, blue: 0xF5 / 255),
        light: royal,
        increasedDark: Color(red: 0x9A / 255, green: 0xAF / 255, blue: 1),
        increasedLight: Color(red: 0x16 / 255, green: 0x2E / 255, blue: 0x9E / 255)
    )
    /// Gold as text or a glyph: deepened in the light so it reads on the warm page.
    private static let defaultGoldText = dynamic(
        dark: gold,
        light: Color(red: 0x94 / 255, green: 0x66 / 255, blue: 0x0C / 255)
    )

    static var royalHighlight: Color { themed(\.accent, fallback: defaultRoyalHighlight) }
    static var goldText: Color { themed(\.presence, fallback: defaultGoldText) }
    static var onAccent: Color { themed(\.accentText, fallback: .white) }
    static var playOnWhite: Color { themed(\.ownBottom, fallback: highlight) }
    static var mediaGlassText: Color { themed(\.text, fallback: .white) }
    static var ownMention: Color { themed(\.ownMention, fallback: gold) }

    static var assistantBubble: Color { themed(\.bubble, fallback: themeAssistantBubble) }
    static let themeAssistantBubble = dynamic(
        dark: Color(red: 0x2A / 255, green: 0x34 / 255, blue: 0x56 / 255),
        light: Color(red: 1, green: 252 / 255, blue: 242 / 255).opacity(0.92)
    )
    static var assistantBubbleText: Color { text }

    static var userBubble: Color { themed(\.ownBottom, fallback: royalDeep) }
    static var userBubbleFill: LinearGradient {
        LinearGradient(colors: [
            themed(\.ownTop, fallback: Color(red: 0x33 / 255, green: 0x58 / 255, blue: 0xE6 / 255)),
            userBubble,
        ], startPoint: .top, endPoint: .bottom)
    }
    static var userBubbleText: Color { themed(\.ownText, fallback: .white) }
    static var otherBubble: Color { themed(\.bubble, fallback: themeOtherBubble) }
    private static let themeOtherBubble = dynamic(
        dark: Color(red: 0x24 / 255, green: 0x37 / 255, blue: 0x5C / 255),
        light: Color.white.opacity(0.88)
    )
    static var otherBubbleText: Color { text }

    /// A person's face until they have a photo: their own in royal, anyone else's in rose.
    static var ownFaceTop: Color { themed(\.ownTop, fallback: Color(red: 0x6B / 255, green: 0x8A / 255, blue: 0xF5 / 255)) }
    static var ownFaceBottom: Color { themed(\.ownBottom, fallback: royalDeep) }
    static let otherFaceTop = Color(red: 0xF4 / 255, green: 0xA9 / 255, blue: 0xBD / 255)
    static let otherFace = Color(red: 0xC9 / 255, green: 0x5F / 255, blue: 0x7E / 255)

    /// A raised surface: rows, cards, the error panel. Firmer with Increase Contrast.
    private static let defaultSurface = dynamic(
        dark: Color.white.opacity(0.08),
        light: Color.white.opacity(0.62),
        increasedDark: Color.white.opacity(0.16),
        increasedLight: Color.white.opacity(0.9)
    )
    /// Something went wrong. Ink or cream on a stronger wash; no new hue.
    static var surface: Color { themed(\.surface, fallback: defaultSurface) }
    static var errorSurface: Color { text.opacity(0.16) }
    /// Something connected, the dot that stands in for the word: the system's own green,
    /// the same as a switch that is on beside it, in either mode.
    static let connected = Color(uiColor: .systemGreen)
    /// Over a blurred thread while a message is lifted for reactions.
    static var scrim: Color {
        let theme = ThemeSelection.shared.theme
        let dark = theme.colors(isDark: true).map { Color(themeRGB: $0.page[0]) } ?? navyDeep
        let light = theme.colors(isDark: false).map { Color(themeRGB: $0.page[0]) } ?? pageSky
        return dynamic(dark: dark.opacity(0.45), light: light.opacity(0.55))
    }
    /// The soft shadow under glass and bubbles: royal in the light, plain dark in the dark.
    static var shadow: Color {
        let light = ThemeSelection.shared.theme.colors(isDark: false)
            .map { Color(themeRGB: $0.ownBottom) } ?? royal
        return dynamic(dark: Color.black.opacity(0.36), light: light.opacity(0.14))
    }
    static var assistantShadow: Color { themed(\.presence, fallback: gold).opacity(0.16) }

    /// Capture the observable theme before constructing UIColor's trait callback.
    /// A change redraws SwiftUI immediately; a system Light/Dark change resolves the
    /// correct palette variant, including menus, sheets and native controls.
    static func themed(_ role: KeyPath<ThemeColors, UInt32>, fallback: Color) -> Color {
        themed(role, theme: ThemeSelection.shared.theme, fallback: fallback)
    }

    static func themed(_ role: KeyPath<ThemeColors, UInt32>, theme: AppTheme, fallback: Color) -> Color {
        let light = theme.colors(isDark: false).map { $0[keyPath: role] }
        let dark = theme.colors(isDark: true).map { $0[keyPath: role] }
        guard light != nil || dark != nil else { return fallback }
        return Color(uiColor: UIColor { traits in
            if let value = traits.userInterfaceStyle == .dark ? dark : light {
                return UIColor(Color(themeRGB: value))
            }
            return UIColor(fallback).resolvedColor(with: traits)
        })
    }

    /// A colour for each scheme, and with Increase Contrast on, the stronger one given for it.
    private static func dynamic(dark: Color, light: Color, increasedDark: Color? = nil, increasedLight: Color? = nil) -> Color {
        Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let plain = isDark ? dark : light
            let increased = isDark ? increasedDark : increasedLight
            return UIColor(traits.accessibilityContrast == .high ? (increased ?? plain) : plain)
        })
    }
}
