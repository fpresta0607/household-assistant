// This person's answer to a reminder by place that would watch them for somebody else,
// "tell Franco when Gia leaves work", signed by this phone exactly as
// deploy/openclaw/plugins/household-app/place-consent.js checks it. Only their own phone
// can say yes, and their phone watches the place only after it has.

import Foundation

enum PlaceAnswer: String, Codable, Sendable {
    case yes, no

    static let version = "household-app/place/v1"

    /// Nil for a message id that would span two lines, which no message has.
    static func signedText(messageId: String, answer: PlaceAnswer, at: Int) -> String? {
        guard !messageId.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            return nil
        }
        return [version, messageId, answer.rawValue, String(at)].joined(separator: "\n")
    }
}
