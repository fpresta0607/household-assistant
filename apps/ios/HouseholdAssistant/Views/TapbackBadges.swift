// A message's reactions on its bubble's top corner, as Messages shows tapbacks: a small
// glass badge for each emoji, overlapping, the one that came last in front, with a count
// when more than one chose it. An assistant's reaction is a badge like anyone's.
//
// This phone's own reaction wears a royal rim, as Messages marks yours in blue, and one only
// the assistants gave wears a gold rim, since gold is their presence; the glass itself is
// never filled with either.
//
// VoiceOver reads the badges as one element that says who reacted and how, the way Messages
// does: "Gia loved this, Corey laughed at this".

import SwiftUI

struct TapbackBadges: View {
    let reactions: [RoomReaction]

    @Environment(AppModel.self) private var model
    /// A badge is round and grows with the text, so its emoji is never clipped.
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 26

    var body: some View {
        HStack(spacing: -6) {
            ForEach(Tapback.badges(for: reactions), id: \.emoji) { badge in
                tapbackBadge(badge)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Tapback.spoken(reactions) { author in name(of: author) })
    }

    private func tapbackBadge(_ badge: Tapback.Badge) -> some View {
        HStack(spacing: 2) {
            Text(badge.emoji)
                .font(.footnote)
            if badge.authors.count > 1 {
                Text("\(badge.authors.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .padding(.horizontal, badge.authors.count > 1 ? 7 : 0)
        .frame(minWidth: size, minHeight: size)
        .rainbowGlass(in: Capsule())
        .overlay {
            if let color = rim(of: badge) {
                Capsule()
                    .strokeBorder(color, lineWidth: 1.5)
            }
        }
    }

    /// Royal when this phone's owner chose it, gold when only assistants did, and otherwise
    /// the glass's own rim (GlassRim): the rainbow sheen in the light, gold glass in the dark.
    private func rim(of badge: Tapback.Badge) -> Color? {
        if let me = model.room.me?.person, badge.authors.contains(me) {
            return Palette.highlight
        }
        if badge.authors.allSatisfy({ model.room.participant($0)?.kind == .assistant }) {
            return Palette.gold
        }
        return nil
    }

    private func name(of author: String) -> String {
        if author == model.room.me?.person {
            return "You"
        }
        return model.room.participant(author)?.name ?? "Someone"
    }
}
