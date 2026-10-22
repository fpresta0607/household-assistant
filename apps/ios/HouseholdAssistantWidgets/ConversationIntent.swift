// What Edit Widget asks: which conversation the widget follows.

import AppIntents
import WidgetKit

struct ConversationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Conversation"
    static let description = IntentDescription("Choose the conversation the widget follows.")

    @Parameter(title: "Conversation")
    var conversation: ConversationChoice?
}
