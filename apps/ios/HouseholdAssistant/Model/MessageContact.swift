// Someone in this iPhone's Contacts a message card may be for: their name as Contacts
// shows it, each name they go by, and where a text reaches them. Read on the phone, kept
// in memory while the card is on screen, and never sent anywhere.

import Foundation

struct MessageContact: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    /// Given name, family name and nickname, each on its own.
    let names: [String]
    /// The number or address Messages sends to, a mobile number first. Nil when the
    /// contact has neither.
    let address: String?
}
