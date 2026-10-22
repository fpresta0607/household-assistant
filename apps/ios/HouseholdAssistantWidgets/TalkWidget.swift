// The Lock Screen's Talk button, for a phone whose Lock Screen has room for a circle but
// whose controls at the bottom are taken.

import SwiftUI
import WidgetKit

struct TalkWidget: Widget {
    let kind = "TalkWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TalkTimeline()) { entry in
            TalkWidgetView(assistantName: entry.assistantName)
        }
        .configurationDisplayName("Call")
        .description("Opens Steward AI straight into a call with your assistant.")
        .supportedFamilies([.accessoryCircular])
    }
}
