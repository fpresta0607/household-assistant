// A model by OpenRouter's id, the name a person reads, its company and that company's
// icon. The assistant's fallbacks are these.

import Foundation

struct ModelChoice: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let company: String
    /// A logo's name, or `symbol:` and an SF Symbol's (see `BrandIcon`).
    let icon: String
}
