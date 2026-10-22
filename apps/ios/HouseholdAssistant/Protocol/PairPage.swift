// What `household-app.pair` answers: a page of the two assistants' direct line, oldest
// first, the newest page unless it was asked for the steps before one, and whether any are
// older. The plugin's `pair` event says the line moved, with when, and every sync and
// history page says when it last did (RoomPair).

import Foundation

struct PairPage: Decodable, Equatable, Sendable {
    let events: [PairEvent]
    /// Whether steps older than the page's first are left.
    let more: Bool

    static let eventName = "plugin.household-app.pair"
}
