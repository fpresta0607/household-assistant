// The colour of the ring round a face, from Edit Color in its photo's menu: a few of the
// app's colours, or any colour from the iPhone's picker.
//
// An assistant's ring starts gold, the assistants' own, and its choice is this phone's,
// kept with the rest of Appearance (AppSettings.assistantRings), so every ring of that
// assistant's face reads it at once: the contact page, Chats, the thread, a call and the
// widgets. Revert to default in Appearance puts every ring back to gold.
//
// The family room's starts as its white edge, and its choice is the room's, the same on
// both phones (FamilyLook): it goes to the gateway once, on Done, so one choice is one
// line in the room, and the sheet says so when the gateway refuses it.

import SwiftUI

struct RingColorSheet: View {
    enum Target: Equatable {
        /// An assistant's face, by participant id.
        case assistant(String)
        case family
    }

    let target: Target
    let name: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.self) private var environment
    /// The family room's colour as picked here, sent on Done.
    @State private var picked: RingColor?
    @State private var isSending = false
    @State private var refusal: String?

    init(target: Target, name: String, family: RingColor? = nil) {
        self.target = target
        self.name = name
        _picked = State(initialValue: family)
    }

    struct Choice: Identifiable {
        let name: String
        /// Nil is the face's own: gold for an assistant, white for the family room.
        let ring: RingColor?

        var id: String {
            name
        }
    }

    /// The named rings after the face's own.
    static let colors = [
        Choice(name: "Royal", ring: RingColor(red: 0x23 / 255, green: 0x46 / 255, blue: 0xD8 / 255)),
        Choice(name: "Rose", ring: RingColor(red: 0xD2 / 255, green: 0x3E / 255, blue: 0x77 / 255)),
        Choice(name: "Green", ring: RingColor(red: 0x1E / 255, green: 0x8A / 255, blue: 0x50 / 255)),
        Choice(name: "Teal", ring: RingColor(red: 0x0F / 255, green: 0x87 / 255, blue: 0x98 / 255)),
        Choice(name: "Silver", ring: RingColor(red: 0xC0 / 255, green: 0xC6 / 255, blue: 0xD2 / 255)),
    ]

    static func choices(for target: Target) -> [Choice] {
        [Choice(name: target == .family ? "White" : "Gold", ring: nil)] + colors
    }

    private var ring: RingColor? {
        switch target {
        case .assistant(let assistant):
            return model.settings.assistantRings[assistant]
        case .family:
            return picked
        }
    }

    private func choose(_ ring: RingColor?) {
        switch target {
        case .assistant(let assistant):
            model.settings.assistantRings[assistant] = ring
        case .family:
            picked = ring
        }
    }

    /// What a choice's swatch is drawn in.
    private func swatch(_ ring: RingColor?) -> Color {
        target == .family ? ring?.color ?? .white : ring.ringColor
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                face
                    .padding(.top, 12)
                HStack(spacing: 14) {
                    ForEach(Self.choices(for: target)) { choice in
                        Button {
                            choose(choice.ring)
                        } label: {
                            Circle()
                                .strokeBorder(swatch(choice.ring), lineWidth: 6)
                                .frame(width: 40, height: 40)
                                .overlay {
                                    if ring == choice.ring {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(Palette.text)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(choice.name)
                        .accessibilityAddTraits(ring == choice.ring ? .isSelected : [])
                    }
                }
                ColorPicker("Any colour", selection: Binding {
                    swatch(ring)
                } set: { color in
                    choose(RingColor(color.resolve(in: environment)))
                }, supportsOpacity: false)
                .padding(.horizontal, 24)
                if let refusal {
                    Text(refusal)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(MeshBackground())
            .navigationTitle(target == .family ? "\(name)'s color" : "\(name)'s ring")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if isSending {
                        ProgressView()
                    } else {
                        Button("Done", action: done)
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    @ViewBuilder
    private var face: some View {
        switch target {
        case .assistant(let assistant):
            ParticipantAvatar(participant: model.room.participant(assistant), size: 96)
        case .family:
            FamilyAvatar(participants: model.room.participants, size: 96, ring: picked)
        }
    }

    /// An assistant's ring is already kept; the family room's goes to the gateway, when it
    /// changed.
    private func done() {
        guard target == .family, picked != model.room.familyLook?.ring else {
            dismiss()
            return
        }
        isSending = true
        refusal = nil
        Task {
            do {
                try await model.room.setFamilyColor(picked)
                dismiss()
            } catch {
                refusal = ErrorText.describe(error)
            }
            isSending = false
        }
    }

    /// What VoiceOver says the ring is, on the face it rings.
    static func spokenName(of ring: RingColor?, for target: Target) -> String {
        choices(for: target).first { $0.ring == ring }?.name ?? "Custom"
    }
}
