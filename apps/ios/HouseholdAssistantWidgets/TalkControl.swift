// Talk as a control, for Control Center, the two buttons at the bottom of the Lock
// Screen, and the Action button: one press opens the app straight into hands-free Talk.

import AppIntents
import SwiftUI
import WidgetKit

struct TalkControl: ControlWidget {
    static let kind = "com.siqstack.stewardai.talk"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenTalkIntent()) {
                Label("Call", systemImage: "phone.fill")
            }
        }
        .displayName("Call")
        .description("Opens Steward AI straight into a call with your assistant.")
    }
}
