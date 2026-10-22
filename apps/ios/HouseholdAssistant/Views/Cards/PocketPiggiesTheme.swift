// PocketPiggies' own look, taken from its theme (app/globals.css in the PocketPiggies
// repository): white cards with a long soft shadow, its rainbow, its pastel surfaces, its
// two inks, and its typeface, Space Grotesk, for its numbers and titles.
//
// Space Grotesk ships in the app under the SIL Open Font License (Fonts/, with its licence
// beside it, registered in project.yml), in the two weights the cards use. It grows with
// Dynamic Type as the text style it stands in for does.

import SwiftUI

enum PocketPiggiesTheme {
    /// Space Grotesk Bold, for numbers and titles, at `style`'s size.
    static func bold(_ style: Font.TextStyle) -> Font {
        .custom("SpaceGrotesk-Bold", size: size(of: style), relativeTo: style)
    }

    /// Space Grotesk Medium, for the small labels over them.
    static func medium(_ style: Font.TextStyle) -> Font {
        .custom("SpaceGrotesk-Medium", size: size(of: style), relativeTo: style)
    }

    /// Each text style's size at the default Dynamic Type size, from which it scales.
    private static func size(of style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle:
            return 34
        case .title:
            return 28
        case .title2:
            return 22
        case .title3:
            return 20
        case .headline, .body:
            return 17
        case .callout:
            return 16
        case .subheadline:
            return 15
        case .footnote:
            return 13
        case .caption:
            return 12
        case .caption2:
            return 11
        @unknown default:
            return 17
        }
    }

    static let ink = CardStyle.hex(0x10122B)
    static let mutedInk = CardStyle.hex(0x6D7088)
    static let card = Color.white
    static let shadow = CardStyle.hex(0x141B44).opacity(0.12)

    static let rainbowStops = [CardStyle.hex(0x7B7BFF), CardStyle.hex(0xFF74C6), CardStyle.hex(0xFFB347), CardStyle.hex(0x7EF1D9)]
    /// The gradient PocketPiggies draws at 120 degrees.
    static let rainbow = LinearGradient(colors: rainbowStops, startPoint: .topLeading, endPoint: .bottomTrailing)
    static let rainbowAcross = LinearGradient(colors: rainbowStops, startPoint: .leading, endPoint: .trailing)

    static let surfaces = [CardStyle.hex(0xFFE8FF), CardStyle.hex(0xE0F2FF), CardStyle.hex(0xFFF4E0), CardStyle.hex(0xDCFFF3)]

    /// Each category bar's own pair, light to deep, in the rainbow's order.
    static let barPairs: [[Color]] = [
        [CardStyle.hex(0x7B7BFF), CardStyle.hex(0xA58BFF)],
        [CardStyle.hex(0xFF74C6), CardStyle.hex(0xFF9FD8)],
        [CardStyle.hex(0xFFB347), CardStyle.hex(0xFFD08A)],
        [CardStyle.hex(0x4FD8B8), CardStyle.hex(0x7EF1D9)],
    ]

    static func surface(_ index: Int) -> Color {
        surfaces[index % surfaces.count]
    }

    static func bar(_ index: Int) -> LinearGradient {
        LinearGradient(colors: barPairs[index % barPairs.count], startPoint: .leading, endPoint: .trailing)
    }
}

extension View {
    /// A PocketPiggies card: white, deeply rounded, on a long soft shadow.
    func piggiesCard() -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PocketPiggiesTheme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: PocketPiggiesTheme.shadow, radius: 16, y: 10)
    }
}
