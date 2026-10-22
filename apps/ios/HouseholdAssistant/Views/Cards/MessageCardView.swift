// A text the assistant drafted for him to send from his own iPhone: who it is for, found in
// his Contacts on the phone while the Contacts connector is on, the words, which he can
// change right on the card, and an event when it carries one. Send lifts the card into
// Apple's own message sheet, already filled in with the event attached as a calendar file,
// and nothing goes out until he taps send there. Sent, the card says so and holds still.
// Cancelled, it stays as it was.
//
// When the card finds nobody, or may not look, Choose someone opens Apple's contact picker,
// which needs no permission. While he shares only some of his contacts, one the card cannot
// see is shared from right here with iOS's own button, and the card looks again.
//
// What he did with it is kept in the room (RoomModel.messageCards), so a card scrolled
// away and back still says sent. Until the gateway has kept the reply it cannot be sent.

import ContactsUI
import SwiftUI
import UIKit

struct MessageCardView: View {
    let card: MessageCard
    /// Nil until the gateway has kept the message.
    let messageId: String?

    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion
    @State private var sheet = MessageSheet()
    @State private var picker = RecipientPicker()
    @State private var isLifted = false
    @State private var isFinding = false
    /// Whether iOS's question about Contacts is on screen, when the connector was turned on
    /// before iOS ever asked.
    @State private var isAskingForContacts = false
    @FocusState private var isEditing: Bool

    private var state: MessageCardState {
        messageId.flatMap { model.room.messageCards[$0] } ?? MessageCardState(card: card)
    }

    private func update(_ change: (inout MessageCardState) -> Void) {
        guard let messageId else {
            return
        }
        var next = state
        change(&next)
        model.room.messageCards[messageId] = next
    }

    var body: some View {
        let state = self.state
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(
                symbol: "message.fill",
                tint: CardStyle.messagesGreen,
                kind: "Message",
                title: "To \(state.recipientName(of: card))",
                note: state.isSent ? "Sent" : nil
            )
            who(state)
            words(state)
            if let event = card.event {
                invite(event)
            }
            send(state)
            if let failure = state.failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .transition(.opacity)
            }
        }
        .padding(12)
        .cardPanel()
        .background(MessageSheetSource(sheet: sheet))
        .scaleEffect(isLifted && !reduceMotion ? 1.03 : 1)
        .shadow(color: Palette.royal.opacity(isLifted ? 0.22 : 0), radius: isLifted ? 18 : 0, y: isLifted ? 10 : 0)
        .animation(Motion.lift(reduced: reduceMotion), value: isLifted)
        .animation(Motion.press(reduced: reduceMotion), value: state)
        .haptic(.success, trigger: state.isSent) { _, isSent in
            isSent
        }
        // Again when the Contacts connector is turned on, since off the card has not
        // looked, and not while App Lock holds the app shut, so iOS's question about
        // Contacts never comes before Face ID.
        .task(id: model.settings.shouldLookInContacts && !model.cover.lock.isLocked ? messageId : nil) {
            await findWho()
        }
    }

    // MARK: - Who it is for

    @ViewBuilder
    private func who(_ state: MessageCardState) -> some View {
        switch state.recipient {
        case nil:
            if isAskingForContacts {
                note("Steward AI looks in your contacts on this iPhone to find \(card.to), and sends nothing from them anywhere.")
            } else if isFinding {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Finding \(card.to) in your contacts")
                }
                .font(.caption)
                .foregroundStyle(CardStyle.secondaryInk)
            } else if !model.settings.shouldLookInContacts {
                choosing("Contacts is off in Settings, under Connectors, so choose who it goes to.", state)
            }
        case .one(let contact):
            if let address = contact.address {
                Text(address)
                    .font(.caption)
                    .foregroundStyle(CardStyle.secondaryInk)
            }
        case .several(let contacts):
            VStack(alignment: .leading, spacing: 8) {
                Text("Which \(card.to)?")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CardStyle.secondaryInk)
                ChipFlow(spacing: 8) {
                    ForEach(contacts) { contact in
                        choice(contact, isChosen: state.chosen == contact)
                    }
                }
            }
        case .nobody:
            if model.permissions.state(of: .contacts) == .limited {
                VStack(alignment: .leading, spacing: 8) {
                    note("\(card.to) is not one of the people you share with Steward AI.")
                    ContactAccessButton(queryString: card.to) { _ in
                        Task { @MainActor in
                            lookAgain()
                        }
                    }
                    choose(state)
                }
            } else {
                choosing("No \(card.to) in your contacts.", state)
            }
        case .noAccess:
            choosing("Steward AI may not look in your contacts. You can allow Contacts in your iPhone's Settings, or choose who it goes to.", state)
        }
    }

    private func choice(_ contact: MessageContact, isChosen: Bool) -> some View {
        Button {
            update { $0.chosen = contact }
        } label: {
            Label(contact.name, systemImage: isChosen ? "checkmark.circle.fill" : "person.crop.circle")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(isChosen ? CardStyle.accent : CardStyle.ink)
                .background(.white, in: Capsule())
                .overlay {
                    // Chosen is a ring in the accent, never a fill.
                    Capsule()
                        .strokeBorder(isChosen ? CardStyle.accent : CardStyle.hairline, lineWidth: isChosen ? 1.5 : 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(state.isSent)
        .haptic(.selection, trigger: isChosen)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    /// Why the card has nobody yet, with Choose someone under it.
    private func choosing(_ text: String, _ state: MessageCardState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            note(text)
            choose(state)
        }
    }

    /// Apple's contact picker, where he picks the person and the number or address to text.
    private func choose(_ state: MessageCardState) -> some View {
        Button {
            isEditing = false
            picker.present { contact in
                update {
                    $0.recipient = .one(contact)
                    $0.chosen = nil
                }
            }
        } label: {
            Label("Choose someone", systemImage: "person.crop.circle.badge.plus")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(CardStyle.accent)
                .background(.white, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(CardStyle.hairline, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(state.isSent || messageId == nil)
        .accessibilityIdentifier("message.choose-someone")
        .accessibilityHint("Opens your contacts to pick who the text goes to")
    }

    /// Its whole height, so a note of two lines is never cut to one in a newly arrived
    /// card, as a screenshot of a text with an event showed.
    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(CardStyle.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - The words

    private func words(_ state: MessageCardState) -> some View {
        TextField("Message", text: Binding { self.state.words } set: { words in update { $0.words = words } }, axis: .vertical)
            .lineLimit(1...8)
            .font(.body)
            .foregroundStyle(CardStyle.ink)
            .focused($isEditing)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(isEditing ? CardStyle.accent.opacity(0.5) : CardStyle.hairline)
            }
            .disabled(state.isSent || messageId == nil)
            .accessibilityLabel("Words of the text")
    }

    // MARK: - The event

    /// The event it carries, as it goes with the text: a calendar file the person taps to
    /// add to their calendar.
    private func invite(_ event: EventCard) -> some View {
        HStack(spacing: 12) {
            DateTile(date: event.start)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(CardStyle.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(event.details(isDayShown: false))
                    .font(.footnote)
                    .foregroundStyle(CardStyle.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(CardStyle.hairline)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Invite to \(event.title), \(event.details(isDayShown: true))")
        .accessibilityIdentifier("message.invite")
    }

    // MARK: - Send

    @ViewBuilder
    private func send(_ state: MessageCardState) -> some View {
        if state.isSent {
            Label("Sent in Messages", systemImage: "checkmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(CardStyle.accent)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(.white, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(CardStyle.accent.opacity(0.35), lineWidth: 1)
                }
                .transition(.opacity)
        } else if MessageSheet.canSend {
            Button {
                openSheet()
            } label: {
                Label("Send in Messages", systemImage: "paperplane.fill")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 28)
            }
            .accentGlass(CardStyle.accent)
            .disabled(!state.canSend || messageId == nil || isLifted)
            .accessibilityHint("Opens Messages with the text filled in. Nothing is sent until you send it there.")
        } else {
            note("This iPhone cannot send texts.")
        }
    }

    private func openSheet() {
        isEditing = false
        let state = self.state
        isLifted = true
        let isShown = sheet.present(to: state.address, words: state.words, event: card.event, isZooming: !reduceMotion) { result in
            isLifted = false
            update { $0.finish(result) }
        }
        if !isShown {
            isLifted = false
        }
    }

    /// Looks him up once, when the card first shows: iOS asks for Contacts here only when
    /// the connector was turned on before iOS ever asked (ContactsLookup). Not in the
    /// screenshot tests or the demo, which have no Contacts, unless a UI test lets the demo
    /// use the Simulator's (DemoContacts).
    private func findWho() async {
        guard messageId != nil, model.permissions.isAllowedToAskForContacts else {
            return
        }
        let step = ContactsLookup.step(for: state, isContactsOn: model.settings.shouldLookInContacts, access: MessageContacts.access)
        switch step {
        case .leave:
            return
        case .noAccess:
            update { $0.recipient = .noAccess }
        case .ask, .read:
            isAskingForContacts = step == .ask
            isFinding = true
            let found = await MessageContacts.find(card.to)
            isAskingForContacts = false
            isFinding = false
            update { $0.recipient = MessageRecipient.matching(card.to, in: found) }
        }
    }

    /// Once iOS's button has shared the person, the card looks for them again.
    private func lookAgain() {
        update { $0.recipient = nil }
        Task {
            await findWho()
        }
    }
}

/// A plain UIKit view the card sits on, for UIKit's zoom to grow the message sheet out of.
private struct MessageSheetSource: UIViewRepresentable {
    let sheet: MessageSheet

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        sheet.source = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}
}
