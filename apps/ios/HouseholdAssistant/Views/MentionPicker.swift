// What typing @ offers, just above the composer: everyone in the room it could mean,
// with their faces and who they are to this phone's owner (Model/Mention.swift). The
// first is the likeliest and wears a royal ring. Picking one writes @ and their name.

import SwiftUI

struct MentionPicker: View {
    let candidates: [Mention.Candidate]
    let onPick: (RoomParticipant) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(candidates.enumerated()), id: \.element.participant.id) { index, candidate in
                Button {
                    onPick(candidate.participant)
                } label: {
                    HStack(spacing: 11) {
                        ParticipantAvatar(participant: candidate.participant, size: 36)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(candidate.participant.name)
                                .font(.body)
                                .foregroundStyle(Palette.text)
                            if let role = candidate.role {
                                Text(role)
                                    .font(.footnote)
                                    .foregroundStyle(Palette.secondaryText)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .overlay {
                        if index == 0 {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Palette.highlight.opacity(0.45), lineWidth: 1.2)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Writes their name")
            }
        }
        .padding(6)
        .liquidGlass(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}
