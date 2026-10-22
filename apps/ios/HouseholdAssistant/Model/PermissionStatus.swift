// Where one permission stands, as iOS records it, in the app's own three words.

import Foundation

enum PermissionStatus: Equatable, Sendable {
    case notAsked, allowed, denied

    var label: String {
        switch self {
        case .notAsked:
            return "Not asked"
        case .allowed:
            return "On"
        case .denied:
            return "Off"
        }
    }

    /// One answer for a permission made of several, as voice is of the microphone and
    /// speech recognition: still to ask while any part is, on only when every part is.
    static func combined(_ parts: [PermissionStatus]) -> PermissionStatus {
        if parts.contains(.notAsked) {
            return .notAsked
        }
        return parts.allSatisfy { $0 == .allowed } ? .allowed : .denied
    }
}
