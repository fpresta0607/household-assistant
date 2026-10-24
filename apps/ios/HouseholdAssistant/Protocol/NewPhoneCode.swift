// A setup code for a new iPhone of this phone's person, as their gateway issues it: the
// same single-use code `household-app.pair` gives whoever runs the box, and the link that
// opens it in the app.
// It works once, for ten minutes, so the phone shows it only while its page is open.

import Foundation

struct NewPhoneCode: Decodable, Equatable, Sendable {
    let setupCode: String
    let link: URL
    /// Milliseconds since 1970.
    let expiresAtMs: Int
}
