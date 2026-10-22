// The Lock Screen's Call button: the phone the app's own Call button carries, in the
// circle. A tap opens the app straight into a call with the assistant.

import SwiftUI
import WidgetKit

struct TalkWidgetView: View {
    let assistantName: String?

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 22, weight: .semibold))
                Text("Call")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .widgetAccentable()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Call \(assistantName ?? "your assistant")")
        .containerBackground(.clear, for: .widget)
        .widgetURL(AppLink.talk.url)
    }
}
