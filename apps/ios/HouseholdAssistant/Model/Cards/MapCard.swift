// A small map in an assistant's answer: one place, its pin's name, and maybe the way there
// from wherever the phone is, which the phone works out with Apple Maps. The gateway sends
// no picture and never sees the way.

import Foundation

struct MapCard: Decodable, Equatable, Sendable {
    enum Route: String, Decodable, Sendable {
        case driving, walking
    }

    let center: MapPoint
    let label: String?
    let route: Route?

    init(center: MapPoint, label: String?, route: Route?) {
        self.center = center
        self.label = label
        self.route = route
    }

    private enum CodingKeys: String, CodingKey {
        case center, label, route
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        center = try container.decode(MapPoint.self, forKey: .center)
        let named = try container.decodeIfPresent(String.self, forKey: .label)?.trimmingCharacters(in: .whitespacesAndNewlines)
        label = named?.isEmpty == false ? named : nil
        route = try container.decodeIfPresent(Route.self, forKey: .route)
    }

    /// Names the way there for one message's card, so it is worked out once and kept.
    func routeKey(in messageId: String) -> String {
        "\(messageId)|\(center.latitude),\(center.longitude)|\(route?.rawValue ?? "none")"
    }
}
