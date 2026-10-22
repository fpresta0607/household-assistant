// What Precise Location means for the assistant right now, in plain words: precise,
// approximate because its person chose so, or approximate because iOS keeps it so, which
// only iOS Settings can change for good.

import Foundation

enum LocationPrecision: Equatable, Sendable {
    case precise
    case approximate
    case keptApproximate

    /// `isPreciseInIOS` is iOS's own Precise Location for the app, which counts only once
    /// iOS lets it use location at all.
    init(isWanted: Bool, isPreciseInIOS: Bool, isAllowed: Bool) {
        if !isWanted {
            self = .approximate
        } else if isAllowed && !isPreciseInIOS {
            self = .keptApproximate
        } else {
            self = .precise
        }
    }

    func words(assistant: String) -> String {
        switch self {
        case .precise:
            return "\(assistant) gets where you are to within a few metres."
        case .approximate:
            return "Off sends only the neighbourhood."
        case .keptApproximate:
            return "iOS keeps your location approximate, so \(assistant) gets only the neighbourhood. Turn on Precise Location for Steward AI in iOS Settings to change that."
        }
    }
}
