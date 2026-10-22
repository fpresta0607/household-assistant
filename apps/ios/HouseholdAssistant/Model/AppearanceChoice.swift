// Light, dark or automatic, in Appearance. Automatic follows the iPhone.

import Foundation

enum AppearanceChoice: String, CaseIterable, Sendable {
    case light, dark, automatic

    var label: String {
        switch self {
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        case .automatic:
            return "Auto"
        }
    }
}
