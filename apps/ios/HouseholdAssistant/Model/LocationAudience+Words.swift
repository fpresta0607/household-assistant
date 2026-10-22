// Who a location is shared with, in the words the first run and Settings use, with the
// household's own names.

import Foundation

extension LocationAudience {
    func title(assistant: String) -> String {
        switch self {
        case .assistant:
            return "Only with \(assistant)"
        case .family:
            return "With the family room too"
        }
    }

    func detail(assistant: String, otherPerson: String) -> String {
        switch self {
        case .assistant:
            return "\(assistant) uses it in your own thread, when you ask."
        case .family:
            return "\(assistant) can also tell \(otherPerson) in the family room, when asked there."
        }
    }
}
