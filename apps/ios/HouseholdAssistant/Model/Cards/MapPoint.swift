// A place on a card, in degrees: on the earth, or the card is not drawn as one.

import Foundation

struct MapPoint: Codable, Equatable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    private enum CodingKeys: String, CodingKey {
        case latitude, longitude
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        latitude = try container.decode(Double.self, forKey: .latitude)
        longitude = try container.decode(Double.self, forKey: .longitude)
        guard abs(latitude) <= 90, abs(longitude) <= 180 else {
            throw DecodingError.dataCorruptedError(forKey: .latitude, in: container, debugDescription: "not a place on the earth")
        }
    }
}
