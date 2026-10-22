// One face in the family room: an assistant's photo or emoji in its ring, gold unless a
// ring was picked for it, or a person's photo, or their initial, royal for this phone's
// own person and rose for the other.

import SwiftUI

struct ParticipantAvatar: View {
    let participant: RoomParticipant?
    var size: CGFloat = 28

    @Environment(AppModel.self) private var model

    var body: some View {
        if let participant, participant.kind == .assistant {
            AssistantAvatar(emoji: participant.emoji, photo: participant.avatar, size: size, ring: model.settings.assistantRings[participant.id])
        } else {
            ParticipantFace(participant: participant, size: size)
                .clipShape(Circle())
                .accessibilityHidden(true)
        }
    }
}
