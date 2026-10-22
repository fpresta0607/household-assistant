// The model the assistant answers with, and the ones it falls back on, in order, when
// that one is busy.

import Foundation

struct AssistantModel: Decodable, Equatable, Sendable {
    let id: String
    let name: String
    let company: String
    /// A logo's name, or `symbol:` and an SF Symbol's (see `BrandIcon`).
    let icon: String
    let fallbacks: [ModelChoice]
}
