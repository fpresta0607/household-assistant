// A place this phone watches for a reminder by place, after its person tapped Set or said
// yes: kept on the phone only, with which side of the place's edge the person was last
// seen on, so it goes off on crossing it the way the card says and not because they were
// already there when it was set.

import Foundation

struct PlaceWatch: Codable, Equatable, Identifiable, Sendable {
    enum Side: String, Codable, Sendable {
        case inside, outside
    }

    /// The name iOS keeps this phone's place monitor under. CLMonitor stops the app on a
    /// name with anything but letters and digits.
    static let monitorName = "StewardPlaces"

    /// The message whose card asked for it.
    let id: String
    let text: String
    let label: String
    let center: MapPoint
    let radius: Double
    let when: PlaceReminderCard.When
    /// True when this phone watches its person for another's assistant, after their yes:
    /// it then says what happened in the family room, as a reply to the card, instead of
    /// reminding them.
    let repliesInRoom: Bool
    var lastSide: Side?

    init(id: String, text: String, label: String, center: MapPoint, radius: Double, when: PlaceReminderCard.When, repliesInRoom: Bool) {
        self.id = id
        self.text = text
        self.label = label
        self.center = center
        self.radius = radius
        self.when = when
        self.repliesInRoom = repliesInRoom
    }

    /// The place a card names, from the message `id` that holds it.
    init(_ card: PlaceReminderCard, id: String, repliesInRoom: Bool) {
        self.init(id: id, text: card.text, label: card.place.label, center: card.place.center, radius: card.place.radius, when: card.when, repliesInRoom: repliesInRoom)
    }

    /// "Arrived at home", "Left work": the line over the reminder's words when it goes off.
    var happened: String {
        when == .arrive ? "Arrived at \(label)" : "Left \(label)"
    }

    /// What this phone says in the family room when it watches for somebody else.
    var reply: String {
        happened + "."
    }

    /// Whether seeing the person on `side` now is the crossing it waits for.
    func goesOff(seeing side: Side) -> Bool {
        switch (when, lastSide, side) {
        case (.arrive, .outside?, .inside), (.leave, .inside?, .outside):
            return true
        default:
            return false
        }
    }
}
