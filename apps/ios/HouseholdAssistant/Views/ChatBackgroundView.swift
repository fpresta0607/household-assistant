// Seasonal presets apply throughout the app. Default also honors the family room's
// shared Dawn or Night background, which is independent of phone appearance.

import SwiftUI

struct ChatBackgroundView: View {
    let choice: ChatBackground

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if ThemeSelection.shared.palette(for: colorScheme) != nil {
                MeshBackground()
            } else {
                switch choice {
                case .rainbow:
                    MeshBackground()
                case .dawn:
                    LinearGradient(colors: colorScheme == .dark ? Self.dawnDark : Self.dawn, startPoint: .top, endPoint: .bottom)
                case .night:
                    LinearGradient(colors: Self.night, startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private static let dawn = [
        Color(red: 0xDC / 255, green: 0xE7 / 255, blue: 0xFF / 255),
        Color(red: 0xFF / 255, green: 0xF3 / 255, blue: 0xDC / 255),
    ]
    private static let dawnDark = [
        Color(red: 0x16 / 255, green: 0x22 / 255, blue: 0x4D / 255),
        Color(red: 0x3A / 255, green: 0x2E / 255, blue: 0x3A / 255),
    ]
    private static let night = [
        Color(red: 0x1B / 255, green: 0x25 / 255, blue: 0x52 / 255),
        Color(red: 0x0E / 255, green: 0x14 / 255, blue: 0x30 / 255),
    ]

}
