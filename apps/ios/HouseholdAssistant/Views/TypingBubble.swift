// Someone is answering: the typing dots in a bubble of their own colour, an assistant's
// with its gold rim, and the speaker's face beside it in the family room.
//
// While this phone's assistant's run uses a tool, the dots give way to a glass working
// line that says what it is doing, "Checking your budget", its icon in a turning ring,
// edged with the assistant bubbles' own rim rather than the glass's rainbow sheen.
// When the tool is done the dots come back, and the reply takes the bubble's place. Each
// gives way to the other by fading, and the bubble takes its new size at once. However
// quick its tool, each step stays long enough to read (RoomModel.shownStep).

import SwiftUI

struct TypingBubble: View {
    let participant: RoomParticipant?
    let showsFace: Bool
    /// What the assistant is busy with, known only for this phone's own assistant.
    var activity: AssistantActivity? = nil
    /// The other household's assistant, for "Checking with Denise".
    var otherAssistant: String? = nil

    /// When the line last changed, so how long each step held can be logged (ThreadLog).
    @State private var changedAt = Date.now

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if showsFace {
                ParticipantAvatar(participant: participant, size: RoomBubble.faceSize)
            }
            ZStack(alignment: .bottomLeading) {
                if let activity {
                    working(activity)
                        .transition(Motion.rowTransition)
                } else {
                    dots
                        .transition(Motion.rowTransition)
                }
            }
            Spacer(minLength: 56)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .onChange(of: activity) { held, _ in
            if let held {
                ThreadLog.note("step \(held) held \(Int(Date.now.timeIntervalSince(changedAt) * 1000)) ms")
            }
            changedAt = .now
        }
    }

    private var dots: some View {
        TypingDots(color: Palette.secondaryText)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(isAssistant ? Palette.assistantBubble : Palette.otherBubble, in: BubbleShape(isTrailing: false, hasTail: true))
            .overlay {
                if isAssistant { AssistantRim(shape: BubbleShape(isTrailing: false, hasTail: true)) }
            }
            .shadow(color: isAssistant ? Palette.assistantShadow : Palette.shadow, radius: 8, y: 3)
    }

    private func working(_ activity: AssistantActivity) -> some View {
        HStack(spacing: 8) {
            WorkingRing(activity: activity)
            Text(sentence(activity))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.secondaryText)
                .lineLimit(1)
                .contentTransition(.opacity)
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .liquidGlass(in: Capsule())
        .overlay {
            AssistantRim(shape: Capsule())
        }
    }

    /// "Checking your budget": the phrase that follows "Corey is", as a line of its own.
    private func sentence(_ activity: AssistantActivity) -> String {
        let phrase = activity.phrase(otherAssistant: otherAssistant)
        return phrase.prefix(1).uppercased() + phrase.dropFirst()
    }

    private var accessibilityText: String {
        let name = participant?.name ?? "Someone"
        guard let activity else {
            return "\(name) is typing"
        }
        return "\(name) is \(activity.phrase(otherAssistant: otherAssistant))"
    }

    private var isAssistant: Bool {
        participant?.kind == .assistant
    }
}
