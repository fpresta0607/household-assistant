// What the Share Extension hands the app through the App Group: the conversation the
// person picked, the words to send, and the files that go with them, copied into a folder
// of the hand-off's own (ShareOutbox). The extension holds no link to the gateway and no
// key, so the app sends it the way its composer sends, uploaded and signed by this phone.
//
// Compiled into the app, the Share Extension and the Linux tests.

import Foundation

struct ShareHandoff: Codable, Equatable, Identifiable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case photo, video, file
        }

        let kind: Kind
        /// Its file's plain name in the hand-off's folder, which is also what a file is
        /// called when it is sent.
        let file: String
    }

    /// A UUID, which also names the message, so sending it twice is one message.
    let id: String
    let conversation: RoomConversation
    let text: String
    let items: [Item]
    /// When the person tapped Send.
    let at: Date

    /// The message's words: what the person wrote, then the text the other app shared,
    /// then each link it shared that is not in those words already, a line each.
    static func text(words: String, shared: [String], links: [URL]) -> String {
        var lines: [String] = []
        for piece in [words] + shared {
            let line = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty, !lines.contains(line) {
                lines.append(line)
            }
        }
        for link in links.map(\.absoluteString) where !lines.contains(where: { $0.contains(link) }) {
            lines.append(link)
        }
        return lines.joined(separator: "\n")
    }

    /// What it carries, for the room to say it is on its way: "2 photos and a file", or
    /// "your message" when it is words alone.
    var summary: String {
        let counted: [(kind: Item.Kind, one: String, many: String)] = [
            (.photo, "a photo", "photos"),
            (.video, "a video", "videos"),
            (.file, "a file", "files"),
        ]
        let parts = counted.compactMap { kind, one, many -> String? in
            let count = items.filter { $0.kind == kind }.count
            switch count {
            case 0:
                return nil
            case 1:
                return one
            default:
                return "\(count) \(many)"
            }
        }
        guard let last = parts.last else {
            return "your message"
        }
        return parts.count == 1 ? last : parts.dropLast().joined(separator: ", ") + " and " + last
    }
}
