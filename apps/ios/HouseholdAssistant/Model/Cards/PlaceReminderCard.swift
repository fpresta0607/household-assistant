// A reminder by place: what it says, the place, and whether it goes off on arriving there
// or leaving. Nothing is set until its person taps Set on their own iPhone, which then
// watches the place itself, so the place never goes back to the gateway.
//
// `for` names the person it watches when that is not the asking assistant's own person,
// "tell me when Gia leaves work": then only that person's iPhone can watch, and only after
// they say yes on the card.

import Foundation

struct PlaceReminderCard: Decodable, Equatable, Sendable {
    enum When: String, Codable, Sendable {
        case arrive, leave
    }

    struct Place: Decodable, Equatable, Sendable {
        /// How a person says the place after "at": "home", "work".
        let label: String
        let center: MapPoint
        /// Metres round the place that count as being there.
        let radius: Double

        static let standardRadius: Double = 150
        /// iOS cannot watch a smaller circle reliably, and a larger one is no longer a place.
        static let radii: ClosedRange<Double> = 100...1000

        init(label: String, center: MapPoint, radius: Double) {
            self.label = label
            self.center = center
            self.radius = radius
        }

        private enum CodingKeys: String, CodingKey {
            case label, radius
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            label = try container.decode(String.self, forKey: .label).trimmingCharacters(in: .whitespacesAndNewlines)
            center = try MapPoint(from: decoder)
            radius = try container.decodeIfPresent(Double.self, forKey: .radius) ?? Self.standardRadius
            guard !label.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .label, in: container, debugDescription: "a place needs its name")
            }
            guard Self.radii.contains(radius) else {
                throw DecodingError.dataCorruptedError(forKey: .radius, in: container, debugDescription: "a place's circle is 100 to 1000 metres")
            }
        }
    }

    let text: String
    let place: Place
    let when: When
    let `for`: String?

    init(text: String, place: Place, when: When, for person: String?) {
        self.text = text
        self.place = place
        self.when = when
        self.for = person
    }

    private enum CodingKeys: String, CodingKey {
        case text, place, when, `for`
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text).trimmingCharacters(in: .whitespacesAndNewlines)
        place = try container.decode(Place.self, forKey: .place)
        when = try container.decode(When.self, forKey: .when)
        let person = try container.decodeIfPresent(String.self, forKey: .for)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.for = person?.isEmpty == false ? person : nil
        guard !text.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .text, in: container, debugDescription: "a reminder needs its words")
        }
    }
}
