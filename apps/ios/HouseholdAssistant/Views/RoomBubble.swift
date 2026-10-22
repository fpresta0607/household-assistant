// One message. This phone's owner speaks from the right in royal blue, an assistant
// from the left on warm white with its markdown and a gold rim round it (AssistantRim),
// and the other person from the left on frosted white. In the family room
// the speaker's face sits beside the last bubble of a run and the name above the first.
// An answer a skill gave wears that skill's badge above its bubble, what its run changed
// shows as chips under it, the newest answer may offer follow-ups under those, a step
// that waits for a yes is its approval card, and a map a person shared is the map with
// their face on it.
//
// An @mention of anyone in the room is drawn as one, in a person's words and in an
// assistant's alike, and VoiceOver says it as "mentions Corey".
//
// A long press lifts it for reactions, Reply and Copy. A reaction fades onto
// its corner with a small burst, or with no burst under Reduce Motion. A reply still
// streaming shows its words as they come, with no cursor. What comes into a bubble after
// it is drawn, a reaction, a skill's badge or the chips of what a run changed, fades in
// and takes its room at once: nothing in a row moves on a spring.
//
// A bubble is drawn again only when what it shows changes (Equatable, below), not every
// time anything in its thread does.

import SwiftUI
import UIKit

struct RoomBubble: View {
    let message: RoomMessage
    let placement: BubblePlacement
    let conversation: RoomConversation
    let repliedTo: RoomMessage?
    /// The carts in this message that a later message has replaced (CartReplacements).
    let replacedCarts: Set<String>
    /// Given where the message's row is on screen, so it can be lifted from there, and
    /// where a finger pressed it, when one did.
    let onReact: (CGRect, CGPoint?) -> Void
    let onReply: () -> Void
    let onOpenMedia: (RoomMedia) -> Void
    let onRetry: () -> Void
    /// Whether the follow-ups the message offers show under it as chips.
    let offersFollowups: Bool

    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion
    /// Which message a search just brought into view, which glows a moment.
    @Environment(ThreadListState.self) private var list
    /// Set by a long press: the row reads its place on screen once, then hands it on.
    @State private var isMeasuringForReaction = false
    /// Where the finger held, on screen, until the message is lifted.
    @State private var pressedAt: CGPoint?
    /// Counts reactions arriving, so each new one bursts and a removed one does not.
    @State private var bursts = 0

    static let faceSize: CGFloat = 28

    private var participant: RoomParticipant? {
        model.room.participant(message.author)
    }

    private var isOwn: Bool {
        message.author == model.room.me?.person
    }

    private var isAssistant: Bool {
        participant?.kind == .assistant
    }

    private var showsFace: Bool {
        conversation == .family && !isOwn
    }

    /// The skill that answered, named by a badge above an assistant's bubble. In the family
    /// room it takes the place of the name, since the face beside the bubble says who.
    private var skill: CardSkill? {
        isAssistant ? StewardCardParser.skill(in: message.text, isStreaming: message.status == .streaming) : nil
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isOwn {
                Spacer(minLength: 56)
            }
            if showsFace {
                ParticipantAvatar(participant: participant, size: Self.faceSize)
                    .opacity(placement.endsRun ? 1 : 0)
            }
            VStack(alignment: isOwn ? .trailing : .leading, spacing: 4) {
                if let skill {
                    SkillBadge(skill: skill)
                        .padding(.leading, 2)
                        .transition(Motion.rowTransition)
                } else if showsFace, placement.startsRun, let name = participant?.name {
                    Text(name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.secondaryText)
                        .padding(.leading, 12)
                }
                if let repliedTo {
                    ReplyQuote(message: repliedTo, isOwn: isOwn)
                }
                bubble
                    .overlay(alignment: isOwn ? .topLeading : .topTrailing) {
                        ZStack {
                            if !reduceMotion {
                                ReactionBurst(trigger: bursts)
                            }
                            if !message.reactions.isEmpty {
                                TapbackBadges(reactions: message.reactions)
                                    .transition(Motion.rowTransition)
                            }
                        }
                        .offset(x: isOwn ? -12 : 12, y: -14)
                    }
                    .padding(.top, message.reactions.isEmpty ? 0 : 14)
                if isAssistant, !message.did.isEmpty {
                    AssistantChangeChips(changes: message.did)
                        .transition(Motion.rowTransition)
                }
                // An approval card's words are what it would do, not links to preview, and a
                // link inside a card is the card's to show.
                if message.status != .streaming, message.approval == nil {
                    LinkPreviewCard(text: isAssistant ? StewardCardParser.prose(in: message.text) : message.text)
                }
                if offersFollowups, let followups = StewardCardParser.followups(in: message.text) {
                    FollowupChips(followups: followups, conversation: conversation)
                }
                if case .failed(let reason) = message.status {
                    failure(reason)
                }
                if message.status == .waiting {
                    Label("Sends when you're back online", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(Palette.secondaryText)
                }
            }
            if !isOwn {
                Spacer(minLength: 56)
            }
        }
        .background {
            if isMeasuringForReaction {
                GeometryReader { geometry in
                    Color.clear.onAppear {
                        isMeasuringForReaction = false
                        onReact(geometry.frame(in: .global), pressedAt)
                        pressedAt = nil
                    }
                }
            }
        }
        .onChange(of: message.reactions.count) { before, after in
            if after > before {
                bursts += 1
            }
        }
    }

    /// A message that is one voice note, such as a reply the assistant said aloud.
    private var isVoiceNote: Bool {
        message.media.count == 1 && message.media.first?.kind == .voice && message.location == nil
    }

    /// A voice note's words: a voice reply's own, or what the gateway heard a person say,
    /// which is what their assistant answered to.
    private var voiceNoteWords: String? {
        message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? message.heard : message.text
    }

    /// A picture, a file or a map fills the bubble almost to its edge.
    private var isFramed: Bool {
        !message.media.isEmpty || message.location != nil
    }

    private var isFound: Bool {
        list.found == message.id
    }

    private var bubble: some View {
        return VStack(alignment: .leading, spacing: 6) {
            if let location = message.location {
                MapShareCard(message: message, location: location, isOwn: isOwn, foreground: foreground)
            } else if !message.media.isEmpty {
                RoomMediaContent(
                    media: message.media,
                    messageId: message.id,
                    isOwn: isOwn,
                    foreground: foreground,
                    spokenWords: isVoiceNote ? voiceNoteWords : nil,
                    onOpen: onOpenMedia
                )
            }
            // A voice note's words are folded under it, never shown beside it.
            if !isVoiceNote, !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                words
                    .padding(.horizontal, isFramed ? 6 : 0)
            }
        }
        .padding(.horizontal, isFramed ? 4 : 14)
        .padding(.vertical, isFramed ? 4 : 9)
        .background {
            // The shadow is the shape's alone, so the words on it stay crisp.
            BubbleShape(isTrailing: isOwn, hasTail: placement.endsRun)
                .fill(background)
                .shadow(color: shadow, radius: 7, y: 4)
        }
        .overlay {
            if isAssistant && !isOwn {
                AssistantRim(shape: BubbleShape(isTrailing: false, hasTail: placement.endsRun))
            }
        }
        // Found by a search: a royal wash and edge that fade in and out again.
        .overlay {
            BubbleShape(isTrailing: isOwn, hasTail: placement.endsRun)
                .fill(Palette.highlight.opacity(0.16))
                .overlay {
                    BubbleShape(isTrailing: isOwn, hasTail: placement.endsRun)
                        .stroke(Palette.highlight, lineWidth: 2)
                }
                .opacity(isFound ? 1 : 0)
                .animation(Motion.fade, value: isFound)
                .allowsHitTesting(false)
        }
        // Brightens as the gateway keeps it, rather than at once in the middle of its rise.
        .animation(Motion.fade) { $0.opacity(message.status == .sending || message.status == .waiting ? 0.7 : 1) }
        .contentShape(Rectangle())
        .gesture(MessageMenuGesture { point in
            pressedAt = point
            isMeasuringForReaction = true
        })
        .haptic(.impact(weight: .medium), trigger: isMeasuringForReaction) { _, isMeasuring in
            isMeasuring
        }
        // An approval card keeps its two buttons apart, so each can be found and pressed, and
        // so does a card with buttons or links of its own, a checklist's ticks among them.
        .accessibilityElement(children: message.approval == nil && !hasCardControls ? .combine : .contain)
        .accessibilityLabel { label in
            if let name = participant?.name, !isOwn {
                Text(name)
            }
            // Its play and speed buttons become its actions, which left nothing to say what it is.
            if isVoiceNote {
                Text("Voice note")
            }
            if let spoken = spokenWords {
                Text(spoken)
            } else {
                label
            }
        }
        // How the UI tests find a message on screen (ScrollHitchTests).
        .accessibilityIdentifier("room.message")
        .accessibilityAddTraits(isFound ? .isSelected : [])
        // On the element VoiceOver lands on, the message menu's own actions.
        .accessibilityAction(named: "Reply", onReply)
        .accessibilityAction(named: "React") {
            isMeasuringForReaction = true
        }
        // Copy, as the menu offers it, for a message with words.
        .accessibilityActions {
            if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button("Copy") {
                    UIPasteboard.general.string = isAssistant ? MessagePlainText.text(of: message.text, calendar: .current) : message.text
                }
            }
        }
    }

    /// The words as VoiceOver says them when they mention someone, each mention as
    /// "mentions Corey"; nil when they mention nobody, when the message is an approval card,
    /// whose buttons speak for themselves, or when it carries photos or files, which say
    /// what they are in the label it has.
    private var spokenWords: String? {
        guard message.approval == nil, message.media.isEmpty, !mentions.isEmpty else {
            return nil
        }
        guard isAssistant else {
            return Mention.spoken(message.text, spans: mentions)
        }
        let words = MessagePlainText.text(of: message.text, calendar: .current)
        return Mention.spoken(words, spans: Mention.spans(in: words, participants: model.room.participants, me: model.room.me))
    }

    /// Whether one of its cards has buttons or links of its own (CardContent.hasControls).
    private var hasCardControls: Bool {
        isAssistant && StewardCardParser.segments(in: message.text, isStreaming: message.status == .streaming).contains { segment in
            if case .card(let card) = segment {
                return card.content.hasControls
            }
            return false
        }
    }

    /// Everyone in the room the words mention.
    private var mentions: [Mention.Span] {
        Mention.spans(in: message.text, participants: model.room.participants, me: model.room.me)
    }

    @ViewBuilder
    private var words: some View {
        if isAssistant, let approval = message.approval {
            ApprovalCardView(message: message, approval: approval)
        } else if isAssistant {
            RoomMarkdown(message: message, conversation: conversation, replacedCarts: replacedCarts)
                .foregroundStyle(foreground)
                .tint(Palette.highlight)
        } else {
            MentionedText(text: message.text, spans: mentions, isOnOwnBubble: isOwn)
                .foregroundStyle(foreground)
        }
    }

    private func failure(_ reason: String) -> some View {
        Button(action: onRetry) {
            Label(reason, systemImage: "exclamationmark.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Tries to send it again")
    }

    private var foreground: Color {
        if isOwn {
            return Palette.userBubbleText
        }
        return isAssistant ? Palette.assistantBubbleText : Palette.otherBubbleText
    }

    private var background: AnyShapeStyle {
        if isOwn {
            return AnyShapeStyle(Palette.userBubbleFill)
        }
        return AnyShapeStyle(isAssistant ? Palette.assistantBubble : Palette.otherBubble)
    }

    private var shadow: Color {
        if isOwn {
            return Palette.userBubble.opacity(0.22)
        }
        return isAssistant ? Palette.assistantShadow : Palette.shadow
    }
}

/// Two bubbles are the same when they would show the same: the actions are left out,
/// since a closure never equals another, and they act on the message and conversation
/// compared here. Built with `.equatable()`, a bubble whose message did not change is not
/// drawn again when a word streams into another one or a typing bubble comes and goes. It
/// still follows the room's people and its own state, which it reads itself.
extension RoomBubble: Equatable {
    nonisolated static func == (lhs: RoomBubble, rhs: RoomBubble) -> Bool {
        lhs.message == rhs.message
            && lhs.placement == rhs.placement
            && lhs.conversation == rhs.conversation
            && lhs.repliedTo == rhs.repliedTo
            && lhs.replacedCarts == rhs.replacedCarts
            && lhs.offersFollowups == rhs.offersFollowups
    }
}

/// The message a reply answers, small and dimmed above the reply's bubble.
private struct ReplyQuote: View {
    @Environment(AppModel.self) private var model
    let message: RoomMessage
    let isOwn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(Palette.highlight)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.room.participant(message.author)?.name ?? "")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Palette.highlight)
                Group {
                    if let first = message.media.first, message.text.isEmpty {
                        Label(" ", systemImage: RoomMediaSymbol.name(for: first.kind))
                            .labelStyle(.iconOnly)
                    } else if message.location != nil, message.text.isEmpty {
                        Label("Location", systemImage: "location.fill")
                    } else {
                        Text(ReplyPreview.text(
                            of: message.text,
                            isAssistant: model.room.participant(message.author)?.kind == .assistant
                        ))
                    }
                }
                .font(.caption)
                .foregroundStyle(Palette.secondaryText)
                .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(maxWidth: 260, alignment: isOwn ? .trailing : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Replying to \(model.room.participant(message.author)?.name ?? "a message")")
    }
}

/// Six small dots flying out from a reaction as it lands, in royal and gold.
private struct ReactionBurst: View {
    let trigger: Int

    private enum Phase {
        case resting, landed, flown
    }

    var body: some View {
        PhaseAnimator([Phase.resting, .landed, .flown], trigger: trigger) { phase in
            ZStack {
                ForEach(0..<6, id: \.self) { index in
                    let angle = Double(index) / 6 * 2 * .pi
                    let reach: CGFloat = phase == .flown ? 22 : 4
                    Circle()
                        .fill(index.isMultiple(of: 2) ? Palette.highlight : Palette.gold)
                        .frame(width: 5, height: 5)
                        .offset(x: cos(angle) * reach, y: sin(angle) * reach)
                        .opacity(phase == .landed ? 1 : 0)
                }
            }
        } animation: { phase in
            phase == .flown ? Motion.burst : nil
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
