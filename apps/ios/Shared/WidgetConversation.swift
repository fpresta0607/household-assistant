// What every widget for one conversation says, whatever its size: its name, its face, the
// line it leads with, who wrote each line, and what to say when there is nothing yet.
//
// The assistant's thread leads with the last thing the assistant said; the family room
// with whatever was said last, by whoever said it.

import SwiftUI
import UIKit

struct WidgetConversation {
    let conversation: RoomConversation
    let snapshot: WidgetSnapshot
    let photos: [String: UIImage]

    var thread: WidgetSnapshot.Conversation {
        snapshot.conversation(conversation)
    }

    var assistantName: String {
        snapshot.assistantName ?? "your assistant"
    }

    var title: String {
        conversation == .family ? "The Fam" : snapshot.assistantName ?? "Steward AI"
    }

    var featured: WidgetSnapshot.Line? {
        switch conversation {
        case .family:
            return thread.lines.last
        case .direct:
            return thread.lines.last { $0.author == snapshot.assistant }
        }
    }

    /// Said in place of the lines when there are none.
    var emptyText: String {
        if snapshot.assistantName == nil {
            return "Open Steward AI to pair this phone."
        }
        return conversation == .family ? "Nobody has written yet." : "Nothing said yet."
    }

    /// The count on the badge, which stops growing where a badge has room.
    var unreadText: String {
        thread.unread > 99 ? "99+" : "\(thread.unread)"
    }

    /// The assistant's face before the room has said who is in it is the one the
    /// gateway reported.
    var assistantLook: FaceTile.Look {
        snapshot.face(snapshot.assistant).map { FaceTile.Look($0) } ?? .assistant(emoji: snapshot.assistantEmoji)
    }

    func look(of author: String) -> FaceTile.Look {
        if let face = snapshot.face(author) {
            return FaceTile.Look(face)
        }
        return author == snapshot.assistant ? assistantLook : .otherPerson(initial: "?")
    }

    func photo(of author: String?) -> UIImage? {
        author.flatMap { photos[$0] }
    }

    /// "You" for this phone's own person, and everyone else by name.
    func name(of author: String) -> String {
        if author == snapshot.me {
            return "You"
        }
        return snapshot.face(author)?.name ?? (author == snapshot.assistant ? assistantName : "Someone")
    }

    /// A line's words, with the symbol for what was sent when there are none, after its
    /// author's name when `isNamed`. Bold and italics in an assistant's words are drawn.
    func text(of line: WidgetSnapshot.Line, isNamed: Bool) -> Text {
        let words = Text((try? AttributedString(
            markdown: line.text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(line.text))
        let said = line.symbol.map { Text("\(Image(systemName: $0)) \(words)") } ?? words
        return isNamed ? Text("\(Text(name(of: line.author)).fontWeight(.semibold)) \(said)") : said
    }
}
