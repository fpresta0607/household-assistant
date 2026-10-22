// The assistant's face: its photo once one is chosen, or its emoji from the gateway on
// warm white, in a gold ring. Its glow brightens while a reply is arriving and dims
// again after, each a single short fade. It does not breathe: a glow swelling and
// shrinking for as long as someone typed redrew its shadow on every frame.
//
// Gold is the assistants' colour: this ring, the rim round their bubbles, the Talk button.
// The ring and its glow take the colour its person picked with Edit Color instead, where
// they picked one (RingColor). Every face says which ring it wears, so a new one never
// falls back to gold by leaving it out: the Today banner did, and drew gold round a white
// ring's face.

import SwiftUI

struct AssistantAvatar: View {
    let emoji: String?
    var photo: RoomMedia?
    var size: CGFloat = 72
    /// Whether a reply is arriving, which brightens the glow.
    var isBreathing = false
    /// The ring picked for this assistant on this phone; nil draws gold.
    let ring: RingColor?

    var body: some View {
        let ringColor = ring.ringColor
        face
            .clipShape(Circle())
            .overlay {
                Circle().strokeBorder(ringColor, lineWidth: max(1.5, size * 0.035))
            }
            .shadow(color: ringColor.opacity(isBreathing ? 0.55 : 0.2), radius: size * 0.1)
            .animation(Motion.fade, value: isBreathing)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var face: some View {
        if let photo {
            FacePhoto(media: photo, size: size) {
                FaceTile(look: .assistant(emoji: emoji), size: size)
            }
        } else {
            FaceTile(look: .assistant(emoji: emoji), size: size)
        }
    }
}
