// One model from OpenRouter's image or video list, as `household-app.models` answers it
// for a `kind`: its name, company and icon, and its price in the unit OpenRouter bills it
// by, or none when OpenRouter lists none.

import Foundation

struct MediaModel: Decodable, Equatable, Identifiable, Sendable {
    /// Dollars for each of a unit, named so it reads plainly after "per": "million image
    /// tokens", "second at 720p".
    struct Price: Decodable, Equatable, Sendable {
        let dollars: Double
        let per: String
    }

    let id: String
    let name: String
    let company: String
    /// A logo's name, or `symbol:` and an SF Symbol's (see `BrandIcon`).
    let icon: String
    let price: Price?
}
