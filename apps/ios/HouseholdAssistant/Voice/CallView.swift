// A call with the assistant on its own screen: draws the call AppModel holds, which
// started listening as it was placed and keeps listening until it ends, with the speaker
// and Mute beside the red button, and ends with the red button or the word "stop". Once
// it ends, the thread keeps it as one call row with what was said (TalkViewModel). Leaving
// the screen leaves the call on, behind the call bar.
//
// The screen stays awake while it is open: a reply can take two minutes, and the person is
// watching it. At the ear the proximity sensor turns it off instead, while nothing is
// connected (CallAudio). Locking the phone no longer stops the call, since iOS has it as a
// call.

import SwiftUI
import UIKit

struct CallView: View {
    let call: TalkViewModel

    @Environment(AppModel.self) private var model

    var body: some View {
        CallScreen(
            session: call.session,
            state: call.state,
            routing: call.audio.routing,
            level: call.level,
            onFaceTap: { call.tapped() },
            onMute: { call.toggleMute() },
            onSpeaker: { call.toggleSpeaker() },
            onLeave: { model.isCallShown = false },
            onEnd: { call.hangUp() }
        )
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}
