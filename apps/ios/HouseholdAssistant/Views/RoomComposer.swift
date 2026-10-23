// The glass composer: the plus, the field with the camera at its end, and the one big
// microphone, which becomes the send arrow once there is something to send.
//
// The plus turns into a cross and the apps drawer springs out of it, row by row: Photos
// (several at once), Camera, Files of any kind, Scan a document, a Contact as a vCard,
// and a Link, pasted or typed into the words, which the thread unfolds into a preview.
// What is picked waits in the field until it is sent, so several things and the words go
// as one message. In the family room, typing @ offers everyone in the room, and picking
// one writes @ and their name. Asking the assistant about a message from its menu starts
// the draft with a mention of it. Location opens its own menu instead: where the phone
// is, shared at once as a map, once or live.
//
// The big microphone works the way Telegram's does. The note starts the moment a finger
// lands on it, before anything is drawn, so the first word is never lost: the recorder
// is kept ready while the conversation is on screen (VoiceNoteRecorder). Slide left to
// throw the note away, slide up to lock it and talk hands-free, let go to send. A locked
// note is sent with the arrow, or stopped to listen back to first. A tap records
// hands-free as a locked note does: the microphone only ever makes voice notes, and words
// are typed, or spoken through the keyboard's own dictation. Starting, locking and
// cancelling each tap back, and so does every message sent. The rules live in
// VoiceNoteGesture; this draws them and does what they decide.
//
// The bar is one piece of Liquid Glass that flows (GlassMorph): the apps drawer wells out
// of the plus, the field becomes the bar a note records in and the listen-back after it,
// the microphone swells into that bar under the finger, and it becomes the send arrow
// once there is something to send. Royal is only their glyphs and rims.

import AVFoundation
import PhotosUI
import SwiftUI
import UIKit
import VisionKit

struct RoomComposer: View {
    let conversation: RoomConversation
    @Binding var replyingTo: RoomMessage?
    /// The assistant a reply asks, mentioned at the start of the draft and then cleared.
    @Binding var asking: String?
    /// Search, from the plus menu, opens over the thread (ThreadSearchBar).
    let onSearch: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var draft: String
    @State private var draftGeneration = 0
    @State private var staged: [StagedAttachment]
    @State private var isDrawerOpen: Bool
    @State private var isLocationMenuOpen: Bool
    /// The span of a map being shared, while the phone finds where it is.
    @State private var sharingSpan: MapShareSpan?
    @State private var gesture: VoiceNoteGesture
    @State private var recorder: VoiceNoteRecorder
    @State private var player = VoiceNotePlayer.shared
    /// True from a cancel in the middle of a drag until that finger lifts, so the rest
    /// of the drag does not start a second note.
    @State private var isDragSpent = false
    /// True while the microphone's native touch recognizer holds the finger.
    @State private var isTouchingMicrophone = false
    /// Counts the notes thrown away, for the tap that says so.
    @State private var cancels = 0
    /// Counts the messages sent from here, for the light tap each one gives.
    @State private var sends = 0
    @State private var notice: String?
    @State private var picked: [PhotosPickerItem] = []
    @State private var isPickingPhotos = false
    @State private var isImportingFiles = false
    @State private var isShowingCamera = false
    @State private var isScanning = false
    @State private var contactPicker = ContactPicker()
    @State private var isAddingLink = false
    @State private var linkEntry = ""
    @State private var isFocused = false
    @State private var isPastingImages = false
    @Namespace private var glass

    private static let buttonSize: CGFloat = 44
    private static let microphoneOff = "Steward AI needs the microphone for voice notes. Turn it on in Settings."

    /// The starting values let the screenshot tests show the drawer or the location menu
    /// open, a draft in the middle of a mention, attachments waiting to go, and a note being
    /// recorded or listened back to with the levels it heard.
    init(
        conversation: RoomConversation,
        replyingTo: Binding<RoomMessage?>,
        asking: Binding<String?> = .constant(nil),
        draft: String = "",
        staged: [StagedAttachment] = [],
        isDrawerOpen: Bool = false,
        isLocationMenuOpen: Bool = false,
        voiceNote: VoiceNoteGesture = VoiceNoteGesture(),
        levels: [Double] = [],
        keptNote: URL? = nil,
        onSearch: @escaping () -> Void = {}
    ) {
        self.conversation = conversation
        self.onSearch = onSearch
        _replyingTo = replyingTo
        _asking = asking
        _draft = State(initialValue: draft)
        _staged = State(initialValue: staged)
        _isDrawerOpen = State(initialValue: isDrawerOpen)
        _isLocationMenuOpen = State(initialValue: isLocationMenuOpen)
        _gesture = State(initialValue: voiceNote)
        _recorder = State(initialValue: VoiceNoteRecorder(levels: levels, kept: keptNote))
    }

    private var hasWords: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasSomethingToSend: Bool {
        hasWords || !staged.isEmpty
    }

    /// Sending needs only to know who this phone is. With no link, what is sent waits in its
    /// thread and goes out by itself once the link is back (RoomModel.send).
    private var canSend: Bool {
        model.room.me != nil
    }

    /// Longer than the gateway takes, which the composer says before Send, not after.
    private var isTooLong: Bool {
        MessageLength.isTooLong(draft)
    }

    /// A note recording, or stopped and waiting to be listened back to.
    private var isVoiceNoteOpen: Bool {
        gesture.isRecording || gesture.isReviewing
    }

    private var reviewedDuration: Int? {
        if case .reviewing(let durationMs) = gesture.phase {
            return durationMs
        }
        return nil
    }

    /// Who the @ at the end of the draft could mean, in the family room.
    private var mentions: [Mention.Candidate] {
        guard conversation == .family, !isVoiceNoteOpen, let query = Mention.query(in: draft) else {
            return []
        }
        return Mention.candidates(matching: query, participants: model.room.participants, me: model.room.me)
    }

    var body: some View {
        let candidates = mentions
        VStack(spacing: 8) {
            if let replyingTo {
                replyBar(replyingTo)
            }
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .liquidGlass(.regular, in: Capsule())
                    .transition(.opacity)
            }
            if !candidates.isEmpty {
                MentionPicker(candidates: candidates) { participant in
                    draft = Mention.inserting(participant.name, into: draft)
                }
                .padding(.leading, Self.buttonSize + 8)
                .transition(drawerTransition)
            }
            // One container, so the drawer, the plus, the field and the microphone blend
            // and flow into each other's glass. Location's menu is the drawer's glass in its
            // next shape.
            GlassEffectContainer(spacing: 8) {
                VStack(alignment: .leading, spacing: 12) {
                    if isDrawerOpen, !isVoiceNoteOpen {
                        AppsDrawer { item in
                            open(item)
                        }
                        .glassMorph("drawer", in: glass)
                        .transition(Motion.springOutTransition(reduced: reduceMotion))
                    }
                    if isLocationMenuOpen, !isVoiceNoteOpen {
                        LocationShareMenu(sharing: sharingSpan) { span in
                            shareLocation(for: span)
                        }
                        .glassMorph("drawer", in: glass)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(Motion.springOutTransition(reduced: reduceMotion))
                    }
                    HStack(alignment: .bottom, spacing: 8) {
                        leading
                        trailingButton
                    }
                }
            }
        }
        .foregroundStyle(Palette.text)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(alignment: .bottom) {
            // The thread dims behind a note being recorded, as in Telegram.
            if gesture.isRecording {
                Palette.scrim
                    .frame(height: 1600)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(Motion.press(reduced: reduceMotion), value: gesture.phase)
        // Without it the send button's transition has nothing to run on.
        .animation(Motion.press(reduced: reduceMotion), value: hasSomethingToSend)
        // The plus turns into a cross as the drawer springs out of it.
        .animation(Motion.springOut(reduced: reduceMotion), value: isDrawerOpen)
        .animation(Motion.springOut(reduced: reduceMotion), value: isLocationMenuOpen)
        .animation(Motion.arrive(reduced: reduceMotion), value: candidates.map(\.participant.id))
        .animation(Motion.arrive(reduced: reduceMotion), value: staged.map(\.id))
        .animation(Motion.fade, value: notice)
        .onChange(of: isTooLong) { _, tooLong in
            if tooLong {
                notice = MessageLength.refusal
            } else if notice == MessageLength.refusal {
                notice = nil
            }
        }
        .photosPicker(
            isPresented: $isPickingPhotos,
            selection: $picked,
            maxSelectionCount: max(RoomAttachment.mostPerMessage - staged.count, 1),
            selectionBehavior: .ordered,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else {
                return
            }
            picked = []
            Task {
                stage(await AttachmentMaker.picked(items))
            }
        }
        .fileImporter(isPresented: $isImportingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let files) = result {
                stage(files.map { AttachmentMaker.file(at: $0) })
            }
        }
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraPicker { shot in
                isShowingCamera = false
                Task {
                    switch shot {
                    case .photo(let image):
                        stage([await AttachmentMaker.photo(image)])
                    case .video(let file):
                        stage([await AttachmentMaker.video(at: file)])
                        try? FileManager.default.removeItem(at: file)
                    case nil:
                        break
                    }
                }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $isScanning) {
            DocumentScanner { scan in
                isScanning = false
                if let scan {
                    stage([AttachmentMaker.scan(scan)])
                }
            }
            .ignoresSafeArea()
        }
        .onChange(of: isFocused) { _, focused in
            ThreadLog.note("composer focused \(focused)")
            if focused {
                isDrawerOpen = false
                isLocationMenuOpen = false
            }
        }
        // A widget's Write button opens this conversation ready to write in.
        .onChange(of: model.writingIn, initial: true) { _, writing in
            if writing == conversation {
                model.writingIn = nil
                isFocused = true
            }
        }
        // Asked from a message's menu: the draft mentions the assistant first, the reply
        // bar quotes the message, and the keyboard comes up to finish the question.
        .onChange(of: asking, initial: true) { _, name in
            guard let name else {
                return
            }
            asking = nil
            draft = Mention.asking(name, in: draft)
            isFocused = true
        }
        .alert("Add a link", isPresented: $isAddingLink) {
            TextField("Paste or type a link", text: $linkEntry)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Add", action: addLink)
            Button("Cancel", role: .cancel) {
                linkEntry = ""
            }
        } message: {
            Text("It goes in your message, and the chat shows a preview of the page.")
        }
        // A widget's microphone opens this conversation straight into a note, locked,
        // since no finger is holding it.
        .onChange(of: model.recordingIn, initial: true) { _, recording in
            if recording == conversation {
                model.recordingIn = nil
                _ = startNote(isLocked: true)
            }
        }
        // A voice note playing takes the sound; once it lets it go, it is readied for the
        // next note again. Anything else that took it, Talk among them, is caught by the
        // recorder itself at the next touch, a little slower.
        .onChange(of: player.current) { _, current in
            if current == nil {
                recorder.warm()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                recorder.warm()
            case .background:
                leaveTheScreen()
            default:
                break
            }
        }
        .onAppear {
            recorder.warm()
        }
        // The others in the family room see this person typing while the draft has words.
        .onChange(of: draft) { _, text in
            Task {
                await model.room.noteDraft(text, in: conversation)
            }
        }
        // Leaving the conversation throws away a note not sent, and stops the typing.
        .onDisappear {
            Task {
                await model.room.noteDraft("", in: conversation)
            }
            if isVoiceNoteOpen {
                stopListeningBack()
                recorder.cancel()
                gesture.reset()
            }
            recorder.rest()
        }
        .haptic(.impact(weight: .medium), trigger: gesture.isRecording) { _, isRecording in
            isRecording
        }
        .haptic(.impact(flexibility: .rigid), trigger: gesture.phase == .locked) { _, isLocked in
            isLocked
        }
        .haptic(.warning, trigger: cancels)
        .haptic(.impact(weight: .light), trigger: sends)
        .task(id: gesture.isRecording) {
            while gesture.isRecording, !Task.isCancelled {
                gesture.tick(at: Date())
                settle()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// The @ list rises from the bar and settles; with Reduce Motion it fades.
    private var drawerTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.9, anchor: .bottomLeading).combined(with: .opacity)
    }

    // MARK: - Pieces

    private func replyBar(_ message: RoomMessage) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .foregroundStyle(Palette.highlight)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.room.participant(message.author)?.name ?? "")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.highlight)
                Text(message.text.isEmpty ? AttributedString(" ") : ReplyPreview.text(
                    of: message.text,
                    isAssistant: model.room.participant(message.author)?.kind == .assistant
                ))
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            // A finger-sized square, as the message menu's rows are, rather than the bare
            // symbol, whose few points a touch fell past without pressing it.
            Button {
                #if DEBUG
                if DemoLongMessages.isRequested {
                    print("thread.list reply strip cancelled")
                }
                #endif
                replyingTo = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.secondaryText)
            .accessibilityLabel("Cancel reply")
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .liquidGlass(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// The field, or the note in its place while it records or waits to be listened back
    /// to, each the field's own glass in a new shape.
    @ViewBuilder
    private var leading: some View {
        if gesture.isRecording {
            VoiceNoteRecordingBar(gesture: gesture, levels: recorder.levels) {
                gesture.discard()
                settle()
            }
            .glassMorph("field", in: glass)
            .transition(.opacity)
        } else if let durationMs = reviewedDuration, let kept = recorder.kept {
            VoiceNoteReview(file: kept, levels: Waveform.bars(from: recorder.levels), durationMs: durationMs) {
                gesture.discard()
                settle()
            }
            .glassMorph("field", in: glass)
            .transition(.opacity)
        } else {
            plusButton
            field
        }
    }

    /// Opens and closes the apps drawer, turning into a cross while it or the location menu
    /// is open. Its glass is the label's, inside the button, as the send arrow's is: round
    /// the button, the glass's own touch took the tap from it. What is picked waits in the
    /// field, so the drawer opens before the room has said who this phone is.
    private var plusButton: some View {
        Button {
            guard !isLocationMenuOpen else {
                isLocationMenuOpen = false
                return
            }
            isDrawerOpen.toggle()
            ThreadLog.note("apps drawer \(isDrawerOpen ? "open" : "closed")")
            if isDrawerOpen {
                isFocused = false
                notice = nil
            }
        } label: {
            Image(systemName: "plus")
                .font(.title3.weight(.medium))
                .rotationEffect(.degrees(isDrawerOpen || isLocationMenuOpen ? 45 : 0))
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .contentShape(Circle())
                .foregroundStyle(Palette.text)
                .liquidGlass(.regular.interactive(), in: Circle())
                .glassMorph("plus", in: glass)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("composer.plus")
        .accessibilityLabel(isDrawerOpen || isLocationMenuOpen ? "Close the apps" : "Add photos, files, your location and more")
    }

    private var field: some View {
        let generation = draftGeneration
        let text = Binding<String>(get: { draft }, set: { value in
            guard generation == draftGeneration else { return }
            draft = value
        })
        return VStack(alignment: .leading, spacing: 8) {
            if !staged.isEmpty {
                AttachmentTray(staged: staged) { removed in
                    staged.removeAll { $0.id == removed.id }
                }
            }
            HStack(alignment: .bottom, spacing: 4) {
                ComposerTextView(text: text, isFocused: $isFocused,
                    maxLines: textSize.isAccessibilitySize ? 3 : 6) { providers in
                    pasteImages(providers)
                }
                    .id(generation)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("composer.field")
                    .foregroundStyle(Palette.text)
                    .tint(Palette.highlight)
                    .padding(.vertical, 11)
                if isPastingImages {
                    ProgressView().controlSize(.small).accessibilityLabel("Adding image")
                }
                if !hasSomethingToSend {
                    Button("Take a photo or video", systemImage: "camera.fill") {
                        openCamera()
                    }
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Palette.secondaryText)
                    .frame(width: 34, height: Self.buttonSize)
                    .transition(.opacity)
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.top, staged.isEmpty ? 0 : 12)
        .liquidGlass(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .glassMorph("field", in: glass)
    }

    @ViewBuilder
    private var trailingButton: some View {
        if gesture.phase == .locked {
            sendButton("Send voice note") {
                gesture.send(at: Date())
                settle()
            }
            .overlay {
                stopButton
                    .offset(y: -96)
            }
        } else if gesture.isReviewing {
            sendButton("Send voice note") {
                gesture.send(at: Date())
                settle()
            }
        } else if hasSomethingToSend, !gesture.isRecording {
            sendButton("Send", action: sendDraft)
                .disabled(!canSend || isTooLong || isPastingImages)
                .opacity(canSend && !isTooLong && !isPastingImages ? 1 : 0.4)
        } else {
            microphone
        }
    }

    /// The arrow in the big microphone's place, the same size and the same glass, so the
    /// microphone becomes it: a royal arrow in a royal ring.
    private func sendButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Palette.highlight)
                .frame(width: MicrophoneOrb.size, height: MicrophoneOrb.size)
                .liquidGlass(.regular.interactive(), in: Circle())
                .overlay { Circle().strokeBorder(Palette.highlight.opacity(0.55), lineWidth: 1.5) }
                .glassMorph("voice", in: glass)
        }
        .buttonStyle(.plain)
        .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
        .accessibilityLabel(label)
    }

    /// Where the lock was once a note locks, as in Telegram: stop, to listen back first.
    private var stopButton: some View {
        Button {
            gesture.stop(at: Date())
            settle()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.red)
                .frame(width: 46, height: 46)
                .contentShape(Circle())
                .liquidGlass(.regular.interactive(), in: Circle())
                .glassMorph("stop", in: glass)
        }
        .buttonStyle(.plain)
        .transition(.opacity)
        .accessibilityLabel("Stop and listen back")
    }

    /// Hold to record and let go to send, or tap to record hands-free. The note starts on
    /// touch down, so the first word is never lost, and a touch too short to have said
    /// anything keeps it recording, locked; the lock rises above as the finger slides up.
    /// VoiceOver's double tap starts a locked note, hands-free.
    private var microphone: some View {
        MicrophoneOrb(
            mode: gesture.phase == .holding ? .holding : .idle,
            level: recorder.levels.last ?? 0,
            cancelProgress: gesture.cancelProgress,
            lockProgress: gesture.lockProgress,
            glass: glass
        )
        .contentShape(Circle())
        .gesture(VoiceNotePressGesture(
            onBegin: {
                isTouchingMicrophone = true
                guard !isDragSpent else { return }
                ChatTiming.touchedMicrophone()
                var instant = Transaction()
                instant.disablesAnimations = true
                instant.addAnimationCompletion {
                    MainActor.assumeIsolated { ChatTiming.recordingSettled() }
                }
                if !withTransaction(instant, { startNote(isLocked: false, at: Date()) }) {
                    isDragSpent = true
                }
            },
            onChange: { translation in
                guard !isDragSpent else { return }
                gesture.drag(x: translation.width, y: translation.height)
                if case .finished = gesture.phase { isDragSpent = true }
                settle()
            },
            onEnd: { cancelled in
                isTouchingMicrophone = false
                if cancelled, gesture.phase == .holding {
                    // An interrupted touch must never send a partial note.
                    gesture.discard()
                    settle()
                    isDragSpent = false
                } else {
                    liftOff("released", at: Date())
                }
            }
        ))
        .disabled(!canSend)
        .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
        .accessibilityLabel("Record a voice note")
        .accessibilityHint("Hold and let go to send, or tap to record hands-free")
        .accessibilityIdentifier("composer.microphone")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            _ = startNote(isLocked: true)
        }
    }

    // MARK: - Doing

    /// Starts a note now: the picture of it at once, in the frame the finger landed in, and
    /// the microphone's input right behind it, off the touch (VoiceNoteRecorder), so the
    /// touch never waits for the sound. The note is timed from `moment`, when the finger
    /// landed. A microphone that would not start takes the note back and says so. A
    /// microphone never asked for is asked for, and the note starts on the next touch, or
    /// straight away when nobody is holding it. A note is only ever started from nothing: one
    /// recording, kept to listen back to, or whose start is still under way stays the note.
    private func startNote(isLocked: Bool, at moment: Date = Date()) -> Bool {
        guard gesture.phase == .idle, !recorder.isStarting else {
            return false
        }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            if isLocked {
                gesture.startLocked(at: moment)
            } else {
                gesture.press(at: moment)
            }
            ThreadLog.note("voice note started \(isLocked ? "locked" : "held")")
            notice = nil
            isDrawerOpen = false
            isFocused = false
            if player.current != nil {
                player.stop()
            }
            Task {
                guard let refusal = await recorder.begin() else {
                    return
                }
                notice = refusal
                if isVoiceNoteOpen {
                    isDragSpent = isTouchingMicrophone
                    gesture.reset()
                }
            }
            return true
        case .undetermined:
            Task {
                guard await AVAudioApplication.requestRecordPermission() else {
                    notice = Self.microphoneOff
                    return
                }
                recorder.warm()
                if isLocked {
                    _ = startNote(isLocked: true)
                } else {
                    notice = "Now hold the microphone to record"
                }
            }
            return false
        default:
            notice = Self.microphoneOff
            return false
        }
    }

    /// The finger came off the microphone at `moment`: a held note goes, as in Telegram and
    /// Messages. A system-cancelled touch discards the held note instead.
    private func liftOff(_ how: String, at moment: Date) {
        isDragSpent = false
        guard gesture.phase == .holding else {
            return
        }
        ThreadLog.note("voice note \(how)")
        gesture.release(at: moment)
        settle()
    }

    /// Does what the note's phase now asks: keeps a stopped note to listen back to, or
    /// acts on a finished one and readies the next.
    private func settle() {
        switch gesture.phase {
        case .reviewing:
            Task {
                await recorder.stop()
            }
        case .finished(let outcome):
            ThreadLog.note("voice note finished \(outcome)")
            stopListeningBack()
            switch outcome {
            case .send(let durationMs):
                ChatTiming.sent(isVoiceNote: true)
                Task {
                    if let note = await recorder.finish(durationMs: durationMs) {
                        send(text: "", attachments: [note])
                    }
                }
            case .cancelled:
                recorder.cancel()
                cancels += 1
            case .tooShort:
                // Stopped or sent before anything was said.
                recorder.cancel()
            }
            gesture.reset()
        case .idle, .holding, .locked:
            break
        }
    }

    private func stopListeningBack() {
        if let kept = recorder.kept, player.current == VoiceNoteReview.playerId(for: kept) {
            player.stop()
        }
    }

    /// The app is leaving the screen: a locked note is kept to listen back to on the way
    /// back, a held one is thrown away, and the sound kept ready is given back.
    private func leaveTheScreen() {
        if gesture.phase == .locked {
            gesture.stop(at: Date())
            settle()
        } else if gesture.phase == .holding {
            recorder.cancel()
            gesture.reset()
        }
        recorder.rest()
    }

    /// What is added, after whatever the draft already said.
    private static func joining(_ added: String, to draft: String) -> String {
        guard let last = draft.last else {
            return added
        }
        return draft + (last.isWhitespace ? "" : " ") + added
    }

    private func open(_ item: AppsDrawer.Item) {
        isDrawerOpen = false
        notice = nil
        switch item {
        case .photos:
            isPickingPhotos = true
        case .camera:
            openCamera()
        case .files:
            isImportingFiles = true
        case .scan:
            if VNDocumentCameraViewController.isSupported {
                isScanning = true
            } else {
                notice = "This iPhone cannot scan documents"
            }
        case .contact:
            contactPicker.present { contact in
                Task {
                    stage([await AttachmentMaker.contact(contact)])
                }
            }
        case .link:
            isAddingLink = true
        case .location:
            isLocationMenuOpen = true
        case .search:
            onSearch()
        }
    }

    /// Shares where the phone is as a map in this conversation, and says why when it cannot.
    private func shareLocation(for span: MapShareSpan) {
        sharingSpan = span
        Task {
            let refusal = await model.shareMap(in: conversation, for: span)
            sharingSpan = nil
            isLocationMenuOpen = false
            notice = refusal
        }
    }

    /// Puts the web address typed or pasted after the words, where the thread finds it and
    /// unfolds its preview once it is sent.
    private func addLink() {
        let entered = linkEntry
        linkEntry = ""
        guard let link = LinkPreviewStore.link(in: entered) else {
            notice = "That is not a web address"
            return
        }
        draft = Self.joining(link.absoluteString, to: draft)
        isFocused = true
    }

    private func openCamera() {
        isDrawerOpen = false
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            notice = "This iPhone has no camera Steward AI can use"
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            notice = "Allow the camera for Steward AI in Settings"
        default:
            isShowingCamera = true
        }
    }

    /// Adds what was made to what waits in the field, as long as one message can still
    /// carry all of it, and says why anything was left out.
    private func stage(_ made: [AttachmentMaker.Made]) {
        var ready: [StagedAttachment] = []
        var refusal: String?
        for result in made {
            switch result {
            case .success(let item):
                ready.append(item)
            case .failure(let reason):
                refusal = reason.reason
            }
        }
        if !ready.isEmpty {
            let all = staged + ready
            if let tooMuch = RoomAttachment.refusal(sizes: all.map(\.attachment.data.count)) {
                refusal = tooMuch
            } else {
                staged = all
            }
        }
        notice = refusal
    }

    private func pasteImages(_ providers: [NSItemProvider]) {
        guard !isPastingImages else { return }
        guard staged.count + providers.count <= RoomAttachment.mostPerMessage else {
            notice = "Up to ten things go in one message"
            return
        }
        let generation = draftGeneration
        isPastingImages = true
        Task { @MainActor in
            let made = await AttachmentMaker.pasted(providers)
            isPastingImages = false
            guard generation == draftGeneration else { return }
            stage(made)
        }
    }

    private func sendDraft() {
        guard !isPastingImages else { return }
        ChatTiming.sent(isVoiceNote: false)
        let text = draft
        let attachments = staged.map(\.attachment)
        let wasFocused = isFocused
        draftGeneration += 1
        let generation = draftGeneration
        draft = ""
        staged = []
        isDrawerOpen = false
        send(text: text, attachments: attachments)
        if wasFocused {
            Task { @MainActor in
                await Task.yield()
                guard generation == draftGeneration else { return }
                isFocused = true
            }
        }
    }

    private func send(text: String, attachments: [RoomAttachment]) {
        let reply = replyingTo?.id
        replyingTo = nil
        sends += 1
        Task {
            await model.room.send(text, in: conversation, replyTo: reply, attachments: attachments, waitsForLink: true)
        }
    }
}
