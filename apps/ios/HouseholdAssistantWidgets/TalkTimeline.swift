// Reads the assistant's name from what the app left in the App Group. Like the
// conversation widget, it is reloaded by the app rather than on a schedule.

import WidgetKit

struct TalkTimeline: TimelineProvider {
    func placeholder(in context: Context) -> TalkEntry {
        TalkEntry(date: Date(), assistantName: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (TalkEntry) -> Void) {
        completion(TalkEntry(date: Date(), assistantName: WidgetSnapshot.load().assistantName))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TalkEntry>) -> Void) {
        completion(Timeline(entries: [TalkEntry(date: Date(), assistantName: WidgetSnapshot.load().assistantName)], policy: .never))
    }
}
