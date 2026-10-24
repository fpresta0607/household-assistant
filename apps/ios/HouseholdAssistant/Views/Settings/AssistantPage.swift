// This phone's own assistant's page, like a contact card in Messages: the face, the name,
// Message, Call and Photo, then the voice with a sample, how it talks from calm to lively,
// and its name, answers, model, connectors and notifications. Opened from Settings and by
// tapping the name or face at the top of its own thread.
//
// Every change is signed and sent to this phone's own gateway, and each row shows what
// the gateway read back, with a spinner while a change is on its way and one plain line
// when the gateway refuses.

import SwiftUI

struct AssistantPage: View {
    /// Opened from the top of its own thread, where Message goes back to it.
    var isOpenedFromThread = false

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.reducesMotion) private var reduceMotion
    /// The slider's value while a finger is on it.
    @State private var draggedTone: Double?
    /// Whether a new face is on its way from the face or from Photo, which share it, so
    /// only one can be sent at a time.
    @State private var isSavingFace = false

    var body: some View {
        let settings = model.assistantSettings
        let name = model.assistantName
        ZStack {
            MeshBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ContactHeader(name: name, role: role) {
                        face
                    } actions: {
                        actions
                    }
                    if settings.current != nil {
                        voice(named: name)
                        tone(named: name)
                        details(named: name)
                    } else {
                        loading
                    }
                    SettingsGroup("Ask Siri") {
                        AskSiriNote()
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                // The gap every Settings page leaves above the floating tab bar
                // (SettingsPage), since this page opens from Settings too.
                .padding(.bottom, 48)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .animation(Motion.flip(reduced: reduceMotion), value: settings.current)
        .animation(Motion.flip(reduced: reduceMotion), value: settings.pending)
        .task(id: model.connection.state == .connected) {
            if model.connection.state == .connected {
                await settings.load()
            }
        }
    }

    /// This phone's assistant in the room, for its face.
    private var assistant: RoomParticipant? {
        model.room.me.flatMap { model.room.participant($0.assistant) }
    }

    private var role: String {
        let person = model.room.me.flatMap { model.room.participant($0.person) }?.name
        return person.map { "\($0)'s assistant" } ?? "Your assistant"
    }

    // MARK: - The face, Message, Call and Photo

    /// The face in its ring, gold unless one was picked, glowing, which a tap changes right
    /// here: its photo, or with Edit Color its ring.
    @ViewBuilder
    private var face: some View {
        let avatar = AssistantAvatar(emoji: assistant?.emoji, photo: assistant?.avatar, size: 96, ring: model.assistantRing)
            .shadow(color: model.assistantRing.ringColor.opacity(0.35), radius: 14, y: 8)
        if let assistant {
            FaceChooser(for: assistant, sharedSaving: $isSavingFace, glowReach: .contactFaceGlowReach) {
                ChangeablePhoto {
                    avatar
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("contact.face")
        } else {
            avatar
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button {
            if isOpenedFromThread {
                dismiss()
            } else {
                model.open(.direct)
            }
        } label: {
            ContactAction(title: "Message", symbol: "message.fill")
        }
        .buttonStyle(.plain)
        Button {
            model.open(AppLink.talk)
        } label: {
            ContactAction(title: "Call", symbol: "phone.fill")
        }
        .buttonStyle(.plain)
        if let assistant {
            // Named as it reads, Photo, so VoiceOver tells it from the face above it.
            FaceChooser(for: assistant, spokenLabel: "Photo", sharedSaving: $isSavingFace) {
                ContactAction(title: "Photo", symbol: "camera.fill")
            }
            .buttonStyle(.plain)
            .accessibilityHint("Chooses a new photo for \(assistant.name)")
        }
    }

    // MARK: - The groups

    @ViewBuilder
    private func voice(named name: String) -> some View {
        let settings = model.assistantSettings
        if let voice = settings.voice {
            let words = Self.sampleWords(name)
            SettingsGroup("Voice", refusal: settings.refusal(for: [.voice]) ?? settings.sampleRefusal) {
                HStack(spacing: 0) {
                    VoiceSampleButton(voice: voice.id, words: words, voiceName: voice.name)
                        .padding(.leading, 16)
                    NavigationLink {
                        VoicePage()
                    } label: {
                        SettingsRow(voice.name, subtitle: voice.summary) {
                            HStack(spacing: 12) {
                                VoiceSampleBars(voice: voice.id, words: words)
                                RowValue(isPending: settings.isPending(.voice))
                            }
                        }
                    }
                    .buttonStyle(.settingsRow)
                }
            }
        }
    }

    private func tone(named name: String) -> some View {
        let settings = model.assistantSettings
        let tone = Binding(
            get: { draggedTone ?? Double(settings.tone ?? 50) },
            set: { draggedTone = $0 }
        )
        return SettingsGroup("How \(name) talks", refusal: settings.refusal(for: [.tone])) {
            HStack(spacing: 12) {
                Text("Calm")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                Slider(value: tone, in: 0...100, step: 1) { isEditing in
                    if !isEditing {
                        commitTone()
                    }
                }
                .tint(Palette.highlight)
                .accessibilityLabel("How \(name) talks")
                .accessibilityValue(Self.toneWords(Int(tone.wrappedValue)))
                Text("Lively")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                if settings.isPending(.tone) {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func details(named name: String) -> some View {
        let settings = model.assistantSettings
        return SettingsGroup(
            note: "Changes go to \(name)'s gateway, which checks they come from your iPhone, and the page shows them once the gateway confirms.",
            refusal: settings.refusal(for: [.name, .length, .model])
        ) {
            NavigationLink {
                NamePage()
            } label: {
                SettingsRow("Name") {
                    RowValue(text: settings.name, isPending: settings.isPending(.name))
                }
            }
            .buttonStyle(.settingsRow)
            NavigationLink {
                ChoicePage(
                    title: "Answers",
                    choices: AnswerLength.allCases,
                    selection: settings.length,
                    isPending: settings.isPending(.length),
                    note: "How much \(name) says in each answer.",
                    refusal: settings.refusal(for: [.length]),
                    label: { $0.label }
                ) { length in
                    Task {
                        await settings.change(.length, to: length.rawValue)
                    }
                }
            } label: {
                SettingsRow("Answers") {
                    RowValue(text: settings.length?.label, isPending: settings.isPending(.length))
                }
            }
            .buttonStyle(.settingsRow)
            NavigationLink {
                ModelPage()
            } label: {
                SettingsRow("Models") {
                    RowValue(text: settings.current?.model.name, isPending: settings.isPending(.model))
                }
            }
            .buttonStyle(.settingsRow)
            NavigationLink {
                ConnectorsPage()
            } label: {
                SettingsRow("Connectors") {
                    RowValue(text: "\(model.connectorsOn) on")
                }
            }
            .buttonStyle(.settingsRow)
            NavigationLink {
                NotificationsPage()
            } label: {
                SettingsRow("Notifications") {
                    RowValue(
                        text: settings.notificationChoice(in: .direct).label,
                        isPending: settings.isPending(.notifications(.direct))
                    )
                }
            }
            .buttonStyle(.settingsRow)
        }
    }

    @ViewBuilder
    private var loading: some View {
        let settings = model.assistantSettings
        SettingsGroup {
            SettingsRow(settings.errorText ?? "Asking \(model.assistantName)'s gateway") {
                if settings.errorText == nil {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Changing

    private func commitTone() {
        guard let dragged = draggedTone else {
            return
        }
        draggedTone = nil
        let value = Int(dragged.rounded())
        guard value != model.assistantSettings.tone else {
            return
        }
        Task {
            await model.assistantSettings.change(.tone, to: String(value))
        }
    }

    /// What the gateway speaks a voice's sample as.
    static func sampleWords(_ name: String) -> String {
        "Hi, I'm \(name). This is how I sound."
    }

    private static func toneWords(_ tone: Int) -> String {
        switch tone {
        case ..<34:
            return "Calm"
        case ..<67:
            return "In between"
        default:
            return "Lively"
        }
    }
}
