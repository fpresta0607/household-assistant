// The five reactions a long press offers, as Messages has its tapbacks: a heart, a thumbs
// up, a laugh, two exclamation marks and a question mark. The assistants react with the
// same five, through the gateway's household_react tool, and every reaction, theirs and the
// people's, shows on its bubble the same way.
//
// Any other emoji, picked from the emoji keyboard past the five or sent before tapbacks,
// shows the same way, and VoiceOver names it by its emoji.

import Foundation

enum Tapback: String, CaseIterable, Sendable {
    case heart = "\u{2764}\u{FE0F}"
    case thumbsUp = "\u{1F44D}"
    case laugh = "\u{1F602}"
    case emphasis = "\u{203C}\u{FE0F}"
    case question = "\u{2753}"

    /// One badge on a bubble: an emoji, and everyone who reacted with it, in the order they did.
    struct Badge: Equatable, Sendable {
        let emoji: String
        let authors: [String]
    }

    var emoji: String {
        rawValue
    }

    /// What VoiceOver calls it on the reaction bar, as Messages names its tapbacks.
    var name: String {
        switch self {
        case .heart:
            return "Heart"
        case .thumbsUp:
            return "Thumbs up"
        case .laugh:
            return "Ha ha"
        case .emphasis:
            return "Exclamation marks"
        case .question:
            return "Question mark"
        }
    }

    /// What someone did to a message with it, as Messages says it: "Gia loved this".
    var verb: String {
        switch self {
        case .heart:
            return "loved"
        case .thumbsUp:
            return "liked"
        case .laugh:
            return "laughed at"
        case .emphasis:
            return "emphasized"
        case .question:
            return "questioned"
        }
    }

    /// The one emoji `typed` is, as a reaction picked from the emoji keyboard, or nil when
    /// it is anything else: nothing, letters, digits, or more than one emoji. Spaces round
    /// it are left out.
    static func reaction(typed: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 1, let character = trimmed.first, isEmoji(character) else {
            return nil
        }
        return trimmed
    }

    /// Whether `character` is drawn as an emoji: one that is an emoji unless asked
    /// otherwise, or one that may be and asks to be, with the emoji selector or a skin
    /// tone after it. A digit, a hash or a copyright sign alone is text.
    private static func isEmoji(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        guard let first = scalars.first, first.properties.isEmoji else {
            return false
        }
        return first.properties.isEmojiPresentation
            || scalars.dropFirst().contains { $0 == "\u{FE0F}" || $0.properties.isEmojiPresentation }
    }

    /// A message's reactions as its bubble shows them: each emoji once, in the order it first
    /// arrived, so the badge that came last is drawn in front.
    static func badges(for reactions: [RoomReaction]) -> [Badge] {
        var badges: [Badge] = []
        for reaction in reactions {
            if let index = badges.firstIndex(where: { $0.emoji == reaction.emoji }) {
                badges[index] = Badge(emoji: reaction.emoji, authors: badges[index].authors + [reaction.author])
            } else {
                badges.append(Badge(emoji: reaction.emoji, authors: [reaction.author]))
            }
        }
        return badges
    }

    /// What VoiceOver says of a message's reactions, one each, in the order they came:
    /// "Gia loved this, Corey laughed at this". `name` says who a participant is, "You" for
    /// this phone's owner.
    static func spoken(_ reactions: [RoomReaction], name: (String) -> String) -> String {
        reactions
            .map { reaction in
                guard let tapback = Tapback(rawValue: reaction.emoji) else {
                    return "\(name(reaction.author)) reacted with \(reaction.emoji)"
                }
                return "\(name(reaction.author)) \(tapback.verb) this"
            }
            .joined(separator: ", ")
    }
}
