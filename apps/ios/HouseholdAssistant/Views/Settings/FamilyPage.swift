// The family room's own page, opened from the top of the room like a group's card in
// Messages: its photo, which a tap changes right here with the same choice and crop as
// Account's, or with Edit Color the ring round it, its name, Message, its appearance, and the
// four in it with their faces. Either person may change the photo, the color and the
// appearance, and the gateway shows one look on both iPhones, with a line in the room for
// each change (FamilyLook). Auto draws the room on each phone's own background; Custom on
// one background for everyone, the latest custom one whoever chose it. This phone's
// assistant's row opens its page, and the other assistant's opens hers, which only shows
// her.

import SwiftUI

struct FamilyPage: View {
    /// Opened from the top of the room, where Message goes back to it.
    var isOpenedFromThread = false

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.reducesMotion) private var reduceMotion
    /// Why the last change to the look did not go through, until the next one.
    @State private var lookRefusal: String?
    /// The appearance on its way to the gateway, shown at once.
    @State private var sendingLook: FamilyLook?

    /// What the room is called, at its top and in Chats.
    static let name = "The Fam"

    var body: some View {
        let participants = model.room.participants
        let look = sendingLook ?? model.room.familyLook ?? .standard
        ZStack {
            MeshBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ContactHeader(name: Self.name, role: "Family room, \(participants.count) people") {
                        FaceChooser(faceId: RoomModel.familyFaceId, name: Self.name, ringTarget: .family, glowReach: .contactFaceGlowReach) {
                            ChangeablePhoto {
                                FamilyAvatar(participants: participants, size: 96, ring: look.ring)
                                    .shadow(color: look.ring.map { $0.color.opacity(0.35) } ?? Palette.shadow, radius: 14, y: 8)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("family.face")
                    } actions: {
                        Button {
                            if isOpenedFromThread {
                                dismiss()
                            } else {
                                model.open(.family)
                            }
                        } label: {
                            ContactAction(title: "Message", symbol: "message.fill")
                        }
                        .buttonStyle(.plain)
                    }
                    appearance(look)
                    SettingsGroup("In the room", note: "Everyone in the family room sees its photo, on both iPhones.") {
                        // Who each one is to this phone's person, as the @ picker says it.
                        ForEach(Mention.candidates(matching: "", participants: participants, me: model.room.me), id: \.participant.id) { member in
                            row(member.participant, role: member.role)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Auto or Custom, and Custom's background, for everyone in the room.
    private func appearance(_ look: FamilyLook) -> some View {
        SettingsGroup(
            "Appearance",
            note: look.appearance == .auto
                ? "Each iPhone draws the room on its own chat background."
                : "The room is drawn on this background on both iPhones.",
            refusal: lookRefusal
        ) {
            GlassSegmentedControl(choices: FamilyLook.Appearance.allCases, selection: Binding {
                look.appearance
            } set: { appearance in
                change(look, to: appearance, background: nil)
            }) { $0.label }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .accessibilityIdentifier("family.appearance")
            if look.appearance == .custom {
                HStack(spacing: 12) {
                    ForEach(FamilyLook.backgrounds, id: \.self) { choice in
                        let isChosen = look.sharedBackground == choice
                        Button {
                            change(look, to: .custom, background: choice)
                        } label: {
                            BackgroundTile(isChosen: isChosen) {
                                ChatBackgroundView(choice: choice)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(choice.label)
                        .accessibilityAddTraits(isChosen ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }
        }
        .animation(Motion.flip(reduced: reduceMotion), value: look.appearance)
    }

    /// Sends a change to the look, shown at once and put back if the gateway refuses it.
    private func change(_ look: FamilyLook, to appearance: FamilyLook.Appearance, background: ChatBackground?) {
        guard appearance != look.appearance || (background != nil && background != look.sharedBackground) else {
            return
        }
        lookRefusal = nil
        var next = look
        next.appearance = appearance
        if let background {
            next.background = background
        }
        sendingLook = next
        Task {
            do {
                try await model.room.setFamilyAppearance(appearance, background: background)
            } catch {
                lookRefusal = ErrorText.describe(error)
            }
            // A newer change on its way keeps showing until its own answer.
            if sendingLook == next {
                sendingLook = nil
            }
        }
    }

    /// One of the four: an assistant's row opens their page, a person's only shows who it is.
    @ViewBuilder
    private func row(_ participant: RoomParticipant, role: String?) -> some View {
        let line = SettingsRow(participant.name, subtitle: role) {
            ParticipantAvatar(participant: participant, size: 40)
        } trailing: {
            if participant.kind == .assistant {
                RowValue()
            }
        }
        if participant.id == model.room.me?.assistant {
            NavigationLink {
                AssistantPage()
            } label: {
                line
            }
            .buttonStyle(.settingsRow)
        } else if participant.kind == .assistant {
            NavigationLink {
                PeerAssistantPage()
            } label: {
                line
            }
            .buttonStyle(.settingsRow)
        } else {
            line
        }
    }
}
