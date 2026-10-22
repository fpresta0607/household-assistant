// The family room's shared backgrounds. Phone appearance uses complete AppTheme presets.

import Foundation

enum ChatBackground: String, CaseIterable, Sendable {
    case rainbow, dawn, night

    var label: String {
        switch self {
        case .rainbow:
            return "Rainbow"
        case .dawn:
            return "Dawn"
        case .night:
            return "Night"

        }
    }
}

