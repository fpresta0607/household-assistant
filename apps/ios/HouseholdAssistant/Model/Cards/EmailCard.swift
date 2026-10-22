// An email the assistant found, laid out like one: from, to, subject and body.
//
// Reply opens Mail. The card's sender is often only a name ("Maple Elementary"), and then
// the reply starts with nobody in To and only the subject filled, which is still the
// right place to begin.

import Foundation

struct EmailCard: Decodable, Equatable, Sendable {
    let from: String
    let to: [String]
    let subject: String
    let body: String

    init(from: String, to: [String], subject: String, body: String) {
        self.from = from
        self.to = to
        self.subject = subject
        self.body = body
    }

    private enum CodingKeys: String, CodingKey {
        case from, to, subject, body
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        from = try container.decode(String.self, forKey: .from)
        to = try container.decodeIfPresent([String].self, forKey: .to) ?? []
        subject = try container.decode(String.self, forKey: .subject)
        body = try container.decode(String.self, forKey: .body)
    }

    /// "Maple Elementary" from "Maple Elementary <office@maple.example>".
    var senderName: String {
        guard let open = from.firstIndex(of: "<"), open > from.startIndex else {
            return from
        }
        return from[..<open].trimmingCharacters(in: .whitespaces)
    }

    /// The address in angle brackets, or the whole sender when that is an address.
    var senderAddress: String? {
        if let open = from.firstIndex(of: "<"), let close = from.lastIndex(of: ">"), open < close {
            let address = from[from.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            return address.contains("@") ? address : nil
        }
        let bare = from.trimmingCharacters(in: .whitespaces)
        return bare.contains("@") && !bare.contains(" ") ? bare : nil
    }

    var replyURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = senderAddress ?? ""
        let isReply = subject.lowercased().hasPrefix("re:")
        components.queryItems = [URLQueryItem(name: "subject", value: isReply ? subject : "Re: " + subject)]
        return components.url
    }

    /// The whole email, for the clipboard.
    var plainText: String {
        var lines = ["From: " + from]
        if !to.isEmpty {
            lines.append("To: " + to.joined(separator: ", "))
        }
        lines.append("Subject: " + subject)
        return lines.joined(separator: "\n") + "\n\n" + body
    }
}
