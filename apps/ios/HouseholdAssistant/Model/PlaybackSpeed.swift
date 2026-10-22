// The speed chip on a voice note, which goes round one, one and a half and two times.

import Foundation

enum PlaybackSpeed: Double, CaseIterable, Sendable {
    case normal = 1
    case faster = 1.5
    case fastest = 2

    var next: PlaybackSpeed {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }

    var label: String {
        switch self {
        case .normal:
            return "1x"
        case .faster:
            return "1.5x"
        case .fastest:
            return "2x"
        }
    }
}
