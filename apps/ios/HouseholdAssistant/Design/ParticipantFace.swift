// Somebody in the room as a square tile: their photo once one is chosen, and their
// initial or emoji until it has loaded, or when there is none.

import SwiftUI

struct ParticipantFace: View {
    let participant: RoomParticipant?
    let size: CGFloat

    var body: some View {
        if let photo = participant?.avatar {
            FacePhoto(media: photo, size: size) {
                FaceTile(participant: participant, size: size)
            }
        } else {
            FaceTile(participant: participant, size: size)
        }
    }
}
