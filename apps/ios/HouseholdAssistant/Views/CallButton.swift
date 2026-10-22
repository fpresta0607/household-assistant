// The phone at the top right of Chats and of this phone's own thread: it calls the
// assistant, as the Phone app would, on the call screen (CallView). Its glyph is in the
// microphone's colour for the look in use (Palette.highlight), not the assistants' gold.

import SwiftUI

struct CallButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.open(AppLink.talk)
        } label: {
            Image(systemName: "phone.fill").foregroundStyle(Palette.highlight)
        }
        .accessibilityLabel("Call \(model.assistantName)")
    }
}
