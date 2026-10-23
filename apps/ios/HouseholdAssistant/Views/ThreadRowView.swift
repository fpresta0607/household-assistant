// One row of a conversation's thread, drawn in a cell of the thread's list (ThreadList):
// a message with the time above it when an hour has passed and "Delivered" or who has read
// it under this phone's newest kept message; a call that ended; the spinner while older
// messages are read; the hello in an empty thread; someone typing, which says what this
// phone's assistant is doing while it works; something shared from another app; or a change
// to the family room's look, as a line with its time.
//
// Everything a row shows comes in its ThreadRow, apart from the room's people and the
// app's settings, which it reads from the model itself. A long press lifts a message
// from its bubble's frame on screen.

import SwiftUI

struct ThreadRowView: View {
    let row: ThreadRow
    let conversation: RoomConversation
    let actions: ThreadActions

    @Environment(AppModel.self) private var model

    var body: some View {
        switch row.content {
        case .older:
            ProgressView()
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
        case .hello:
            hello
        case .message(let content):
            messageRow(content)
        case .typing(let typing):
            TypingBubble(
                participant: model.room.participant(typing.participant),
                showsFace: conversation == .family,
                activity: typing.activity,
                otherAssistant: model.otherAssistantName
            )
            .padding(.top, 12)
        case .shared(let shared):
            SharedOnItsWay(handoff: shared.handoff, isConnected: shared.isConnected)
                .padding(.top, 12)
        case .look(let line):
            lookLine(line)
        }
    }

    /// "Franco changed the group color · 7:42 PM", centred between the messages.
    private func lookLine(_ line: FamilyLookLine) -> some View {
        let name = model.room.participant(line.author)?.name ?? "Someone"
        return Text("\(line.words(by: name)) \u{00B7} \(line.sentAt.formatted(date: .omitted, time: .shortened))")
            .font(.caption)
            .foregroundStyle(Palette.secondaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .accessibilityIdentifier("room.look-line")
    }

    /// One view per message, so it arrives with its time and its receipt.
    private func messageRow(_ content: ThreadRow.Message) -> some View {
        let message = content.message
        let placement = content.placement
        return VStack(spacing: 0) {
            if let divider = placement.divider {
                dividerLabel(divider)
                    .padding(.top, content.isFirst ? 4 : 16)
                    .padding(.bottom, 8)
            }
            Group {
                if let call = message.call {
                    CallLogRow(call: call, assistantName: model.assistantName) {
                        actions.onOpenCall(message)
                    }
                } else {
                    // Drawn again only when what it shows changes, not when anything else
                    // in its row does, such as the receipt under it.
                    bubble(content)
                        .equatable()
                }
            }
            .padding(.top, content.isFirst || placement.divider != nil ? 0 : (placement.startsRun ? 12 : 4))
            // While it is lifted, the message is only where it floats.
            .opacity(content.isLifted ? 0 : 1)
            .accessibilityValue(MessageTime.divider(for: message.sentAt).time)
            if let readers = content.readers {
                // Its room is there from the moment the message is sent, so the message never
                // moves for it, hidden from sight and from VoiceOver until the gateway has kept
                // the message, and then it fades in.
                ZStack {
                    if message.rev == nil {
                        receipt(readers)
                            .hidden()
                    } else {
                        receipt(readers)
                    }
                }
                .animation(Motion.fade, value: message.rev == nil)
            }
        }
    }

    private func bubble(_ content: ThreadRow.Message) -> RoomBubble {
        let message = content.message
        return RoomBubble(
            message: message,
            placement: content.placement,
            conversation: conversation,
            repliedTo: content.repliedTo,
            replacedCarts: content.replacedCarts,
            onReact: { frame, point in actions.onReact(message, frame, point) },
            onReply: { actions.onReply(message) },
            onOpenMedia: { media in actions.onOpenMedia(media) },
            onRetry: { actions.onRetry(message) },
            offersFollowups: content.offersFollowups
        )
    }

    private var hello: some View {
        VStack(spacing: 12) {
            if conversation == .family {
                FamilyAvatar(participants: model.room.participants, size: 72, ring: model.room.familyLook?.ring)
            } else {
                AssistantAvatar(emoji: model.identity?.emoji, photo: model.assistantPhoto, size: 64, ring: model.assistantRing)
            }
            Image(systemName: "hand.wave.fill")
                .font(.title2)
                .foregroundStyle(Palette.goldText)
                .accessibilityLabel(conversation == .family ? "Say hello to the family" : "Say hello to \(model.assistantName)")
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity)
    }

    /// "Today 6:12 PM", the day in bold.
    private func dividerLabel(_ date: Date) -> some View {
        let divider = MessageTime.divider(for: date)
        return Text("\(Text(divider.day).fontWeight(.semibold)) \(divider.time)")
            .font(.caption)
            .foregroundStyle(Palette.secondaryText)
            .frame(maxWidth: .infinity)
    }

    /// "Delivered", or who has read it, under this phone's newest kept message.
    private func receipt(_ readers: [String]) -> some View {
        let names = readers.compactMap { model.room.participant($0)?.name }.joined(separator: ", ")
        return Group {
            if readers.isEmpty {
                Text("Delivered")
            } else if conversation == .family {
                Text("Read by \(Text(names).fontWeight(.semibold))")
            } else {
                Text("Read")
            }
        }
        .font(.caption2)
        .foregroundStyle(Palette.secondaryText)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.top, 4)
        .padding(.trailing, 4)
        .transition(.opacity)
    }
}

/// Two rows are the same when they would show the same: the actions are left out, since a
/// closure never equals another, and every copy of them acts on the same screen. Built
/// with `.equatable()`, a row whose content did not change is not drawn again when a word
/// streams into another row or the room's typing comes and goes. It still follows the
/// room's people and the app's settings, which it reads itself.
extension ThreadRowView: Equatable {
    nonisolated static func == (lhs: ThreadRowView, rhs: ThreadRowView) -> Bool {
        lhs.row == rhs.row && lhs.conversation == rhs.conversation
    }
}
