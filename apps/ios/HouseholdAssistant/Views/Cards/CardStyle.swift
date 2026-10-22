// How a card inside an assistant's bubble looks: a pale panel on the bubble, the bubble's
// own ink, and the app's blue for what can be tapped.
//
// The hues past Palette's four are the soft rainbow the approved design gives charts,
// card icons and skill badges, and the parchment and wine of scripture and sermons. They
// live here because they belong to the cards and nowhere else in the app.

import SwiftUI
import UIKit

enum CardStyle {
    static var ink: Color { Palette.assistantBubbleText }
    static var secondaryInk: Color { Palette.themed(\.secondary, fallback: ink.opacity(0.62)) }
    static var accent: Color {
        Palette.highlight
    }
    /// Near white on the warm bubble in the light. In the dark the bubble is navy and the
    /// ink cream, so the panel is a faint light wash that the cream still reads on.
    static var panel: Color { Palette.themed(\.surface, fallback: defaultPanel) }
    private static let defaultPanel = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.08) : UIColor(white: 1, alpha: 0.8)
    })
    static var hairline: Color { ink.opacity(0.08) }
    static let cornerRadius: CGFloat = 16

    static let gold = Palette.gold
    static let goldInk = hex(0x94660C)

    // MARK: The rainbow, in the order a chart's bars take it

    static let coral = hex(0xFF6F8A)
    static let sky = hex(0x3AA6F5)
    static let violet = hex(0xA46BFF)
    static let mint = hex(0x2FC79A)
    static let orange = hex(0xFF9D4D)
    static let yellow = hex(0xF2BF3A)
    static let indigo = hex(0x6673FF)

    static let rainbow = [coral, sky, violet, mint, orange, yellow, indigo]
    /// Each hue's lighter top, for a bar that deepens toward its base.
    static let rainbowLight = [hex(0xFFA8B8), hex(0x9FD6FF), hex(0xCFB0FF), hex(0x8FE6C8), hex(0xFFC58F), hex(0xFFE08A), hex(0xA5ADFF)]
    /// Left to right along a single line, the way the approved line graph runs.
    static let lineRainbow = [indigo, sky, mint, yellow, orange, coral]

    static func hue(_ index: Int) -> Color {
        rainbow[index % rainbow.count]
    }

    static func lightHue(_ index: Int) -> Color {
        rainbowLight[index % rainbowLight.count]
    }

    // MARK: Scripture and sermons

    static let parchmentTop = hex(0xFFFDF7)
    static let parchmentBottom = hex(0xFBF4E3)
    static let parchmentInk = hex(0x2A2214)
    static let wine = hex(0x8A3046)

    // MARK: Lists and web search, each in its own hue and a deeper ink for words on it

    static let listsGreen = hex(0x2EA078)
    static let listsInk = hex(0x1F7A59)
    static let searchTeal = hex(0x2FA7C0)
    static let searchInk = hex(0x1C7488)

    // MARK: A text, in the green of Messages

    static let messagesGreen = hex(0x34C759)

    static func hex(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

extension View {
    /// The pale rounded panel every card but scripture and PocketPiggies sits on: white, or
    /// a wash of the colour of the skill that answered.
    func cardPanel(tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: CardStyle.cornerRadius, style: .continuous)
        return background(tint.map { AnyShapeStyle($0.opacity(0.1)) } ?? AnyShapeStyle(CardStyle.panel), in: shape)
            .overlay {
                shape.strokeBorder(tint.map { $0.opacity(0.16) } ?? CardStyle.hairline)
            }
    }
}
