// What the gateway's `icon` names, as a small tile: a company's mark tinted in its own
// colour on white (the Simple Icons marks, which are CC0), OpenRouter's and DeepSeek's own
// icons on white, PocketPiggies' and SIQsermon's own icons edge to edge, Z.ai as a
// monogram since it has no mark there, and an SF Symbol on a royal tile. A logo this
// phone does not have shows the first letter of `fallbackName`.

import SwiftUI

struct BrandTile: View {
    let icon: BrandIcon
    var fallbackName = ""
    var size: CGFloat = 30

    init(_ name: String, fallbackName: String = "", size: CGFloat = 30) {
        icon = BrandIcon(name: name)
        self.fallbackName = fallbackName
        self.size = size
    }

    /// Each Simple Icons mark's own colour, as simpleicons.org gives it.
    private static let markColors: [String: Color] = [
        "anthropic": hex(0xD97757),
        "apple": .black,
        "brave": hex(0xFB542B),
        "duckduckgo": hex(0xDE5833),
        "elevenlabs": .black,
        "gmail": hex(0xEA4335),
        "google": hex(0x4285F4),
        "googlecalendar": hex(0x4285F4),
        "googlegemini": hex(0x8E75B2),
        "icloud": hex(0x3693F3),
        "notion": .black,
        "openai": .black,
        "perplexity": hex(0x1FB8CD),
        "telegram": hex(0x26A5E4),
    ]

    /// Drawn as they come, on white.
    private static let pictures: Set<String> = ["openrouter", "deepseek"]
    /// Drawn as they come, edge to edge.
    private static let appIcons: Set<String> = ["pocketpiggies", "siqsermon"]

    var body: some View {
        tile
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(Palette.ink.opacity(0.08), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var tile: some View {
        switch icon {
        case .symbol(let symbol):
            SymbolTile(symbol, color: Palette.royal, size: size)
        case .logo(let name) where Self.appIcons.contains(name):
            Image("Logos/\(name)")
                .resizable()
                .scaledToFill()
        case .logo(let name) where Self.pictures.contains(name):
            Image("Logos/\(name)")
                .resizable()
                .scaledToFit()
                .padding(size * 0.12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
        case .logo(let name):
            if let color = Self.markColors[name] {
                Image("Logos/\(name)")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(color)
                    .padding(size * 0.2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white)
            } else {
                monogram(name == "zai" ? "Z" : String(fallbackName.prefix(1)))
            }
        }
    }

    private func monogram(_ letter: String) -> some View {
        Text(letter)
            .font(.system(size: size * 0.5, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Self.hex(0x1F3BFF))
    }

    nonisolated private static func hex(_ value: Int) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}
