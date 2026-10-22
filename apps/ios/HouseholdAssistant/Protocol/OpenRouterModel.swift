// One model from OpenRouter's public list, as `household-app.models` answers it: text
// models that can call tools, with dollar prices per million tokens.

import Foundation

struct OpenRouterModel: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let company: String
    /// A logo's name, or `symbol:` and an SF Symbol's (see `BrandIcon`).
    let icon: String
    let inputPerMillion: Double
    let outputPerMillion: Double
    let badge: ModelBadge?
}
