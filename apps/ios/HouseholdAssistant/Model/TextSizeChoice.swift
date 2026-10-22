// Text size in Accessibility: like the iPhone's own setting, or one of the standard sizes
// for this app alone, from the smallest to the largest before the accessibility sizes.

import Foundation

enum TextSizeChoice: String, CaseIterable, Sendable {
    case likeIPhone, xSmall, small, medium, large, xLarge, xxLarge, xxxLarge

    /// The sizes the slider steps through, smallest first.
    static let sizes: [TextSizeChoice] = allCases.filter { $0 != .likeIPhone }

    var label: String {
        switch self {
        case .likeIPhone:
            return "Like iPhone"
        case .xSmall:
            return "Smallest"
        case .small:
            return "Smaller"
        case .medium:
            return "Small"
        case .large:
            return "Standard"
        case .xLarge:
            return "Large"
        case .xxLarge:
            return "Larger"
        case .xxxLarge:
            return "Largest"
        }
    }
}
