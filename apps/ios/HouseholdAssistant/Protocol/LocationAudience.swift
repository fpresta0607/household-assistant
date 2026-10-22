// Who may use where a person is, as they chose it on their own iPhone: their own
// assistant, in their own thread, or the family room too, where that assistant can
// answer the other person. Nobody else, and never the other gateway.

import Foundation

enum LocationAudience: String, Codable, CaseIterable, Sendable {
    case assistant, family
}
