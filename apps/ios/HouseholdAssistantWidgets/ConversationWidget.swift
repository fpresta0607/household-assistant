// One conversation, the assistant's thread or the family room, chosen with Edit Widget:
// small, medium and large on the Home Screen, circular, rectangular and inline on the
// Lock Screen. Tapping opens that conversation.
//
// Its kind is the first widget's, so a widget already on a Home Screen becomes this one,
// showing the assistant's thread as it did.

import SwiftUI
import WidgetKit

struct ConversationWidget: Widget {
    let kind = "AssistantWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ConversationIntent.self, provider: ConversationTimeline()) { entry in
            EntryView(entry: entry)
        }
        .configurationDisplayName("Steward AI")
        .description("Your assistant or the family room: the newest messages, and Call.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
        ])
    }
}

/// Hands the view the size iOS is drawing, which only a widget's own view can read, and
/// the iPhone's Reduce Motion: the app's own choice stays in the app, so the widget's
/// motion follows the iPhone.
private struct EntryView: View {
    let entry: ConversationEntry

    @Environment(\.widgetFamily) private var family
    @Environment(\.accessibilityReduceMotion) private var isReducedOnIPhone

    var body: some View {
        ConversationWidgetView(
            family: family,
            conversation: entry.conversation,
            snapshot: entry.snapshot,
            photos: entry.photos
        )
        .environment(\.reducesMotion, isReducedOnIPhone)
    }
}
