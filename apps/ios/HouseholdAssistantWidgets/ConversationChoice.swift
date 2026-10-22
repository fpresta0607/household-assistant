// A conversation a widget can follow, as Edit Widget lists it: this phone's assistant by
// the name its gateway gave it, and the family room. A widget set up before the phone is
// paired follows the assistant.

import AppIntents

struct ConversationChoice: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Conversation"
    static let defaultQuery = Query()

    /// The conversation's own name in the app, `direct` or `family`.
    let id: String
    let name: String
    let symbol: String

    var conversation: RoomConversation {
        RoomConversation(rawValue: id) ?? .direct
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: DisplayRepresentation.Image(systemName: symbol))
    }

    struct Query: EntityQuery {
        func entities(for identifiers: [String]) async throws -> [ConversationChoice] {
            Self.choices().filter { identifiers.contains($0.id) }
        }

        func suggestedEntities() async throws -> [ConversationChoice] {
            Self.choices()
        }

        func defaultResult() async -> ConversationChoice? {
            Self.choices().first
        }

        private static func choices() -> [ConversationChoice] {
            let assistantName = WidgetSnapshot.load().assistantName ?? "Your assistant"
            return [
                ConversationChoice(id: RoomConversation.direct.rawValue, name: assistantName, symbol: "sparkles"),
                ConversationChoice(id: RoomConversation.family.rawValue, name: "The family room", symbol: "person.3.fill"),
            ]
        }
    }
}
