// What the Talk button draws: only who it talks to, for VoiceOver.

import WidgetKit

struct TalkEntry: TimelineEntry {
    let date: Date
    let assistantName: String?
}
