// One theme owns a complete Light and Dark palette; appearance only chooses the variant.
import Foundation

enum AppTheme: String, CaseIterable, Sendable {
    case `default`, spring, winter, christmas, aurora, ember, starlight

    static func saved(_ value: String?) -> Self {
        switch value {
        case "springBloom": return .spring
        case "winterFrost", "winterNight": return .winter
        case "christmasEve": return .christmas
        default: return value.flatMap(Self.init(rawValue:)) ?? .default
        }
    }

    /// Prefer the old active manual mode; Auto keeps the first non-default saved theme.
    static func restored(theme: String?, light: String?, dark: String?, prefersDark: Bool) -> Self {
        if let theme { return saved(theme) }
        let first = saved(prefersDark ? dark : light)
        return first == .default ? saved(prefersDark ? light : dark) : first
    }

    var name: String {
        switch self {
        case .default: return "Default"
        case .spring: return "Spring"
        case .winter: return "Winter"
        case .christmas: return "Christmas"
        case .aurora: return "Aurora"
        case .ember: return "Ember"
        case .starlight: return "Starlight"
        }
    }

    var detail: String {
        switch self {
        case .default: return "The original Steward look"
        case .spring: return "Blush, sage & berry"
        case .winter: return "Snow, moonlight & ice"
        case .christmas: return "Evergreen, cranberry & candlelight"
        case .aurora: return "Northern lights, jade & opal"
        case .ember: return "Autumn copper, porcelain & plum"
        case .starlight: return "Champagne, amethyst & midnight"
        }
    }

    var symbol: String {
        switch self {
        case .default: return "sparkles"
        case .spring: return "leaf"
        case .winter: return "snowflake"
        case .christmas: return "tree"
        case .aurora: return "sparkle"
        case .ember: return "flame"
        case .starlight: return "moon.stars"
        }
    }

    /// One composited decorative layer, bounded for contrast even where motifs overlap.
    var atmosphereOpacity: Double {
        switch self {
        case .aurora, .ember, .starlight: return 0.14
        default: return 0
        }
    }

    func colors(isDark: Bool) -> ThemeColors? {
        switch (self, isDark) {
        case (.default, _): return nil
        case (.aurora, false):
            return ThemeColors(page: [0xF2FBF8, 0xE6F4F2, 0xF0EBFA], text: 0x172F38,
                secondary: 0x425765, accent: 0x155E67, presence: 0x605080,
                bubble: 0xFCFFFE, ownTop: 0x226878, ownBottom: 0x414184,
                surface: 0xF5FAFC, accentText: 0xFFFFFF, rim: [0x377581, 0x6C60A3, 0x387668, 0x377581])
        case (.aurora, true):
            return ThemeColors(page: [0x071B23, 0x103B3D, 0x282342], text: 0xEFFFFB,
                secondary: 0xC4DAD9, accent: 0xA2EBDF, presence: 0xD6C3FA,
                bubble: 0x19343E, ownTop: 0x236575, ownBottom: 0x454180,
                surface: 0x162C37, accentText: 0x09272D, rim: [0x82D8C9, 0xB8A5EB, 0x82CADF, 0x82D8C9])
        case (.ember, false):
            return ThemeColors(page: [0xFFF7ED, 0xF7EBDC, 0xF4E8E9], text: 0x38262A,
                secondary: 0x695052, accent: 0x8C3D24, presence: 0x73425A,
                bubble: 0xFFFBF6, ownTop: 0x99492F, ownBottom: 0x713D53,
                surface: 0xFBF2E9, accentText: 0xFFFFFF, rim: [0xA25F3F, 0x8E6473, 0x92713F, 0xA25F3F])
        case (.ember, true):
            return ThemeColors(page: [0x21131C, 0x3C241F, 0x322234], text: 0xFFF4E5,
                secondary: 0xDEC8BC, accent: 0xFFBF91, presence: 0xE5B4CD,
                bubble: 0x3C292B, ownTop: 0x98482F, ownBottom: 0x713D53,
                surface: 0x32232A, accentText: 0x301B20, rim: [0xE3A77D, 0xCBA5C1, 0xD8B57D, 0xE3A77D])
        case (.starlight, false):
            return ThemeColors(page: [0xFFFBF0, 0xF0EDF9, 0xF5F1E7], text: 0x25243B,
                secondary: 0x5D576E, accent: 0x645092, presence: 0x79551D,
                bubble: 0xFFFDFA, ownTop: 0x5F4A91, ownBottom: 0x34376D,
                surface: 0xF9F6F0, accentText: 0xFFFFFF, rim: [0x99783E, 0x776199, 0x5D7297, 0x99783E])
        case (.starlight, true):
            return ThemeColors(page: [0x111325, 0x27243E, 0x302735], text: 0xFFF7E7,
                secondary: 0xD6CDDE, accent: 0xEACB8A, presence: 0xD4C1FF,
                bubble: 0x29283E, ownTop: 0x5E498E, ownBottom: 0x34376D,
                surface: 0x222338, accentText: 0x241F32, rim: [0xE2C187, 0xBBA7E6, 0xA0BDDF, 0xE2C187])
        case (.spring, false):
            return ThemeColors(page: [0xFFF9F6, 0xF4F8EE, 0xFCEEF4], text: 0x352039,
                secondary: 0x67536A, accent: 0x8B315C, presence: 0x76573D,
                bubble: 0xFFF9FB, ownTop: 0x96385E, ownBottom: 0x7E294F,
                surface: 0xFFFAFC, accentText: 0xFFFFFF, rim: [0xA74A74, 0x8D547E, 0x547866, 0xA74A74])
        case (.spring, true):
            return ThemeColors(page: [0x211827, 0x172820, 0x2A1C2A], text: 0xFFF3F8,
                secondary: 0xD8C3D1, accent: 0xF0B4D0, presence: 0xBBD6BD,
                bubble: 0x382A3A, ownTop: 0x96385E, ownBottom: 0x7E294F,
                surface: 0x302632, accentText: 0x211827, rim: [0xD79AB9, 0xBEA6D2, 0x93BCA2, 0xD79AB9])
        case (.winter, false):
            return ThemeColors(page: [0xF5FAFF, 0xEDF5F8, 0xF3F3FC], text: 0x172E40,
                secondary: 0x506175, accent: 0x245B84, presence: 0x3D657A,
                bubble: 0xFFFFFF, ownTop: 0x28688F, ownBottom: 0x1F5076,
                surface: 0xF8FCFF, accentText: 0xFFFFFF, rim: [0x587E99, 0x65789B, 0x4D8489, 0x587E99])
        case (.christmas, false):
            return ThemeColors(page: [0xFFFAEF, 0xEFF5EC, 0xFAF0F0], text: 0x26392C,
                secondary: 0x56634D, accent: 0x963449, presence: 0x6D5629,
                bubble: 0xFFFCF5, ownTop: 0x8D3045, ownBottom: 0x72263B,
                surface: 0xF7FAF2, accentText: 0xFFFFFF, rim: [0x937138, 0x547962, 0xAA6470, 0x937138])
        case (.christmas, true):
            return ThemeColors(page: [0x091D19, 0x132C25, 0x201B20], text: 0xF7F1E3,
                secondary: 0xCAC8BA, accent: 0xF2C773, presence: 0xF2C773,
                bubble: 0x20392F, ownTop: 0x8D3045, ownBottom: 0x72263B,
                surface: 0x1A322B, accentText: 0x091D19, rim: [0xD1AF69, 0xA3C7AE, 0xE1B7A1, 0xD1AF69])
        case (.winter, true):
            return ThemeColors(page: [0x0C1528, 0x172440, 0x1B1C32], text: 0xEEF5FF,
                secondary: 0xBDCBE0, accent: 0xA9D7FF, presence: 0xC8C0F0,
                bubble: 0x26334C, ownTop: 0x365A90, ownBottom: 0x294575,
                surface: 0x202E45, accentText: 0x0C1528, rim: [0x8EBCDC, 0xB4AEDB, 0x80C8D3, 0x8EBCDC])
        }
    }
}

/// Opaque sRGB roles let previews, app surfaces and contrast checks use identical values.
struct ThemeColors: Equatable, Sendable {
    let page: [UInt32]
    let text: UInt32
    let secondary: UInt32
    let accent: UInt32
    let presence: UInt32
    let bubble: UInt32
    let ownTop: UInt32
    let ownBottom: UInt32
    let surface: UInt32
    let accentText: UInt32
    let rim: [UInt32]
    let ownText: UInt32 = 0xFFFFFF
    let ownMention: UInt32 = 0xFFF0BF
}
