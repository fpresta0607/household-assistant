// An SF Symbol in white on a small coloured tile, the way iOS Settings marks its rows.

import SwiftUI

struct SymbolTile: View {
    let symbol: String
    let fill: AnyShapeStyle
    var size: CGFloat = 30
    @Environment(\.colorScheme) private var scheme

    init(_ symbol: String, color: Color, size: CGFloat = 30) {
        self.init(symbol, fill: AnyShapeStyle(color), size: size)
    }

    init(_ symbol: String, fill: AnyShapeStyle, size: CGFloat = 30) {
        self.symbol = symbol
        self.fill = fill
        self.size = size
    }

    var body: some View {
        Image(systemName: symbol)
            .symbolVariant(.fill)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(ThemeSelection.shared.palette(for: scheme) == nil ? fill : AnyShapeStyle(Palette.userBubbleFill),
                        in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}
