// Reads what the app left in the App Group, for the conversation this widget was set to.
//
// One entry and no refresh schedule: the app reloads the widgets whenever what they show
// changes, so there is nothing to poll.

import WidgetKit

struct ConversationTimeline: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ConversationEntry {
        ConversationEntry(date: Date(), conversation: .direct, snapshot: WidgetSnapshot(), photos: [:])
    }

    func snapshot(for configuration: ConversationIntent, in context: Context) async -> ConversationEntry {
        entry(for: configuration)
    }

    func timeline(for configuration: ConversationIntent, in context: Context) async -> Timeline<ConversationEntry> {
        Timeline(entries: [entry(for: configuration)], policy: .never)
    }

    private func entry(for configuration: ConversationIntent) -> ConversationEntry {
        let snapshot = WidgetSnapshot.load()
        return ConversationEntry(
            date: Date(),
            conversation: configuration.conversation?.conversation ?? .direct,
            snapshot: snapshot,
            photos: WidgetFacePhotos.load(for: snapshot)
        )
    }
}
