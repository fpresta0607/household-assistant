// Apply appearance and accessibility at the root, including sheets and covers.
// Palette carries the chosen theme to shared SwiftUI and UIKit surfaces.

import SwiftUI
import UIKit

struct PhonePreferences: ViewModifier {
    let settings: AppSettings

    @Environment(\.accessibilityReduceMotion) private var isReducedOnIPhone
    @Environment(\.dynamicTypeSize) private var iPhoneTextSize
    @Environment(\.legibilityWeight) private var iPhoneLegibilityWeight

    func body(content: Content) -> some View {
        let textSize = settings.textSize.dynamicTypeSize
        let isTextBold = settings.isTextBold
        return content
            .environment(\.readingStyle, ReadingStyle(
                size: textSize ?? iPhoneTextSize,
                isBold: isTextBold || iPhoneLegibilityWeight == .bold,
                theme: settings.theme
            ))
            .environment(\.reducesMotion, settings.reduceMotion.reducesMotion(whenIPhoneDoes: isReducedOnIPhone))
            .environment(\.isHapticsOn, settings.isHapticsOn)
            .environment(\.rims, RimLook(theme: settings.theme))
            .transformEnvironment(\.dynamicTypeSize) { size in
                if let textSize {
                    size = textSize
                }
            }
            .transformEnvironment(\.legibilityWeight) { weight in
                if isTextBold {
                    weight = .bold
                }
            }
            .preferredColorScheme(settings.appearance.colorScheme)
            .onChange(of: settings.appearance) { _, appearance in
                if appearance == .automatic {
                    followTheIPhone()
                }
            }
    }

    /// Puts every window back on the iPhone's own scheme. On some versions of iOS a nil
    /// `preferredColorScheme` leaves a window on the dark or light it was last set to, so
    /// Auto after Dark stayed dark with the iPhone in light, sheets and covers included.
    private func followTheIPhone() {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows {
            window.overrideUserInterfaceStyle = .unspecified
        }
    }
}

extension View {
    /// Applies this phone's Appearance and Accessibility choices to everything below.
    func phonePreferences(_ settings: AppSettings) -> some View {
        modifier(PhonePreferences(settings: settings))
    }
}

extension TextSizeChoice {
    /// Nil while it follows the iPhone.
    var dynamicTypeSize: DynamicTypeSize? {
        switch self {
        case .likeIPhone:
            return nil
        case .xSmall:
            return .xSmall
        case .small:
            return .small
        case .medium:
            return .medium
        case .large:
            return .large
        case .xLarge:
            return .xLarge
        case .xxLarge:
            return .xxLarge
        case .xxxLarge:
            return .xxxLarge
        }
    }

    /// The app's own size nearest the iPhone's: its largest for the iPhone's accessibility
    /// sizes, which go past it.
    init(nearest size: DynamicTypeSize) {
        switch size {
        case .xSmall:
            self = .xSmall
        case .small:
            self = .small
        case .medium:
            self = .medium
        case .large:
            self = .large
        case .xLarge:
            self = .xLarge
        case .xxLarge:
            self = .xxLarge
        default:
            self = .xxxLarge
        }
    }

    /// The iPhone's own size in the app's words.
    static func label(ofIPhone size: DynamicTypeSize) -> String {
        size.isAccessibilitySize ? "Accessibility size" : TextSizeChoice(nearest: size).label
    }
}

extension AppearanceChoice {
    /// Nil while it follows the iPhone.
    var colorScheme: ColorScheme? {
        switch self {
        case .light:
            return .light
        case .dark:
            return .dark
        case .automatic:
            return nil
        }
    }
}
