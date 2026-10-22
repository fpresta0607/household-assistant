// The family room's face: its own photo once either person has chosen one on its page
// (FamilyPage), and until then the four who are in it, each in a quarter of one circle,
// the way a group shows in Messages, seated as FamilyFaces seats them. The photo is read
// from the room here rather than handed in, so every screen in the app that shows the
// room's face shows it. The widgets and notifications still draw the four faces.
//
// Its edge is white until either person picks the room a colour on its page, the same on
// both phones (FamilyLook); then it is a ring in that colour with its glow, as an
// assistant's face is.

import SwiftUI

struct FamilyAvatar: View {
    let participants: [RoomParticipant]
    var size: CGFloat = 52
    /// The room's colour, nil for its white edge. Every face says which, so a new one
    /// never leaves it out.
    let ring: RingColor?

    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let photo = model.room.familyAvatar {
                FacePhoto(media: photo, size: size) {
                    everyone
                }
            } else {
                everyone
            }
        }
        .clipShape(Circle())
        .overlay {
            if let ring {
                Circle()
                    .strokeBorder(ring.color, lineWidth: max(1.5, size * 0.035))
            } else {
                Circle()
                    .strokeBorder(.white.opacity(0.75), lineWidth: max(1, size * 0.025))
            }
        }
        .shadow(color: ring?.color.opacity(0.2) ?? .clear, radius: size * 0.1)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var everyone: some View {
        let faces = Array(FamilyFaces.arranged(participants).prefix(4))
        let side = size / 2
        if faces.isEmpty {
            Image(systemName: "person.3.fill")
                .font(.system(size: size * 0.36, weight: .semibold))
                .foregroundStyle(Palette.highlight)
                .frame(width: size, height: size)
                .background(Palette.surface)
        } else {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    quarter(faces, 0, side: side)
                    quarter(faces, 1, side: side)
                }
                GridRow {
                    quarter(faces, 2, side: side)
                    quarter(faces, 3, side: side)
                }
            }
        }
    }

    @ViewBuilder
    private func quarter(_ faces: [RoomParticipant], _ index: Int, side: CGFloat) -> some View {
        if index < faces.count {
            ParticipantFace(participant: faces[index], size: side)
        } else {
            Rectangle()
                .fill(Palette.surface)
                .frame(width: side, height: side)
        }
    }
}
