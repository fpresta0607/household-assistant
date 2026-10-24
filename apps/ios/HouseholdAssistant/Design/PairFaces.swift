// The two assistants' faces overlapping, this phone's own in front, for the Corey & Denise
// group: on its row in Chats and at the top of the group.

import SwiftUI

struct PairFaces: View {
    var size: CGFloat = 28

    @Environment(AppModel.self) private var model

    var body: some View {
        let mine = model.room.me?.assistant
        HStack(spacing: -size * 0.3) {
            ForEach(assistants) { assistant in
                ParticipantAvatar(participant: assistant, size: size)
                    .zIndex(assistant.id == mine ? 1 : 0)
            }
        }
        .accessibilityHidden(true)
    }

    /// This phone's own assistant first, then the other.
    private var assistants: [RoomParticipant] {
        let mine = model.room.me?.assistant
        let all = model.room.participants.filter { $0.kind == .assistant }
        return all.filter { $0.id == mine } + all.filter { $0.id != mine }
    }
}
