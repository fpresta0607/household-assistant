// Reduce Motion in Accessibility: like the iPhone's own setting, or on or off for this app
// alone. With it on, every spring and lift in the app becomes a fade (see `Motion`).

import Foundation

enum ReduceMotionChoice: String, CaseIterable, Sendable {
    case likeIPhone, on, off

    var label: String {
        switch self {
        case .likeIPhone:
            return "Like iPhone"
        case .on:
            return "On"
        case .off:
            return "Off"
        }
    }

    func reducesMotion(whenIPhoneDoes isReducedOnIPhone: Bool) -> Bool {
        switch self {
        case .likeIPhone:
            return isReducedOnIPhone
        case .on:
            return true
        case .off:
            return false
        }
    }
}
