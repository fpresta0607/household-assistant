// One conversation: the family room or this phone's own thread with its assistant.
//
// It reads like Messages: bubbles grouped by who spoke, the time when an hour has
// passed, a typing bubble while someone is answering, and "Read" under this phone's
// latest message once someone has seen it. What this phone's assistant does while it uses
// a tool shows in its typing bubble, in either conversation, and no line of its steps
// shows before or around its reply. In this phone's own thread, the assistant's newest
// answer offers what the person may ask next as chips under it. Long press a bubble for its actions. Everything
// that happens arrives through the room model, so this screen only shows it. What was
// shared here from another app shows at the end as on its way until the room sends it,
// and each message can be copied, selected or shared from its long-press menu.
//
// The input bar is never in the way: the thread scrolls under it, and at rest its newest
// message, and whoever is typing under that, sit just above it. The thread's list
// (ThreadList) stands at its end as messages arrive and grow and as the keyboard and
// composer rise and fall, unless the person has scrolled up to read. It opens at its
// newest message, and follows what this phone sends from wherever the person was.
//
// The name and face at the top open that assistant's page, like a contact in Messages:
// this phone's own assistant's from its own thread, with its photo once one is chosen,
// and from the family room the other assistant's, which only shows her. Tapping an
// assistant's @mention in any bubble opens that assistant's page too. In the family room
// a message's menu can ask this phone's assistant about it: a reply quoting it, with the
// assistant mentioned. While the two assistants' direct line moved within the hour, a small
// pill near the top of the family room says so and opens their group (PairMarker). The
// thread is drawn on the background Appearance chose, and on the night's navy it takes the
// dark look. The tab bar steps aside while a conversation is open.
//
// Whatever arrives at the bottom of the thread fades in, what this phone sends rises from
// the composer, and nothing else moves. A picture
// opens into the viewer out of its place in the grid and closes back into the place of
// the one on screen.

import SwiftUI

struct RoomView: View {
    let conversation: RoomConversation

    /// The lifted message's overlay comes in at once, its copy whole where the message sits,
    /// and goes with a fade. Named, with its types spelled out, so the overlay's expression
    /// stays quick for the compiler to check.
    private static let liftTransition = AsymmetricTransition(insertion: IdentityTransition(), removal: FadeAway())

    /// Whose page is open over the conversation: this phone's own assistant's, which it
    /// changes, the other assistant's, which it only shows, or the family room's own.
    private enum AssistantPageKind: Hashable {
        case own, peer, family
    }

    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.readingStyle) private var readingStyle

    private struct Preparation: Hashable {
        let ids: [String]
        let style: ReadingStyle
    }
    @State private var replyingTo: RoomMessage?
    /// The assistant a reply asks, which the composer mentions at the start of the draft.
    @State private var asking: String?
    @State private var reacting: RoomMessage?
    /// Where the lifted message's row was on screen when it was pressed.
    @State private var reactingFrame = CGRect.zero
    /// Where a finger pressed it, which its reactions and menu open beside.
    @State private var reactingPoint: CGPoint?
    /// The lifted message once its copy is over the thread, when its row gives way to it,
    /// so the message is on screen in every frame.
    @State private var liftShown: String?
    @State private var viewing: RoomMedia?
    /// The picture the viewer shows now, which it closes back into.
    @State private var zoomedMedia: String?
    @Namespace private var pictures
    @State private var assistantPage: AssistantPageKind?
    /// Whether the Corey & Denise group is open over the family room, from its marker.
    @State private var isPairOpen = false
    /// The call whose words are open.
    @State private var openedCall: RoomMessage?
    private struct Selection: Identifiable {
        let id = UUID()
        let text: String
    }
    @State private var selection: Selection?
    /// Older pages are a bounded reading window, separate from live arrivals.
    @State private var history: RoomThread?
    @State private var historyGeneration = 0
    /// What the thread's rows share, here so the lifted message draws as its row does.
    @State private var listState = ThreadListState()
    /// Searching the conversation, from the plus menu (CFO notes section 5).
    @State private var search = ThreadSearchModel()
    /// The message the thread is asked to bring into view, a search's pick.
    @State private var threadJump: ThreadJump?

    /// The screenshot tests open it with a message already lifted for reactions, or with
    /// its menu open, or with the assistant's page already open over it.
    init(
        conversation: RoomConversation,
        reacting: RoomMessage? = nil,
        reactingFrame: CGRect = .zero,
        isAssistantPageOpen: Bool = false
    ) {
        self.conversation = conversation
        _reacting = State(initialValue: reacting)
        _reactingFrame = State(initialValue: reactingFrame)
        _assistantPage = State(initialValue: isAssistantPageOpen ? (conversation == .family ? .peer : .own) : nil)
    }

    var body: some View {
        let thread = history ?? model.room.thread(conversation)
        ZStack {
            ChatBackgroundView(choice: background)
            // Over the thread, so its showing never moves a row.
            messages(thread)
                .overlay(alignment: .bottom) {
                    searchResults
                }
                .overlay(alignment: .top) {
                    VStack(spacing: 8) {
                        ConnectionBanner()
                        if conversation == .family {
                            PairMarker { isPairOpen = true }
                        }
                    }
                    .padding(.top, 8)
                }
                .environment(\.mediaZoom, pictures)
            .blur(radius: reacting == nil ? 0 : 14)
        }
        // A mention's link opens whom it names; every other link opens as it would anywhere.
        .environment(\.openURL, OpenURLAction { url in
            guard let mentioned = Mention.participantId(in: url) else {
                return .systemAction
            }
            openPage(of: mentioned)
            return .handled
        })
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button {
                    assistantPage = conversation == .family ? .family : .own
                } label: {
                    header
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("room.header")
                .accessibilityHint(conversation == .family ? "Opens the family room's page" : "Opens \(model.assistantName)'s page")
            }
            // Whole-chat export is intentionally absent; individual message actions
            // remain in their long-press menus.
            ToolbarItem(placement: .topBarTrailing) {
                if conversation == .direct {
                    CallButton()
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar
                .blur(radius: reacting == nil ? 0 : 14)
                .allowsHitTesting(reacting == nil)
        }
        .overlay {
            if let reacting {
                ReactionOverlay(
                    message: reacting,
                    rowFrame: reactingFrame,
                    pressPoint: reactingPoint,
                    isOwn: reacting.author == model.room.me?.person,
                    onShown: { liftShown = reacting.id },
                    onReact: { emoji in react(to: reacting, with: emoji) },
                    onReply: {
                        replyingTo = reacting
                        self.reacting = nil
                    },
                    onAsk: askAction(about: reacting),
                    onSelectText: { words in
                        selection = Selection(text: words)
                        self.reacting = nil
                    },
                    onDismiss: { self.reacting = nil }
                ) {
                    liftedBubble(reacting, in: thread)
                }
                .transition(Self.liftTransition)
            }
        }
        // For each voice note, in its row and in the lifted copy alike (RoomMediaContent).
        .environment(listState)
        .environment(\.colorScheme, backgroundScheme ?? colorScheme)
        .toolbarColorScheme(backgroundScheme, for: .navigationBar)
        .fullScreenCover(item: $viewing) { media in
            MediaViewer(media: media) { shown in
                zoomedMedia = shown.id
            }
            .zoomTransition(from: zoomedMedia ?? media.id, in: pictures)
        }
        .navigationDestination(isPresented: $isPairOpen) {
            PairView()
        }
        .navigationDestination(item: $assistantPage) { page in
            switch page {
            case .own:
                AssistantPage(isOpenedFromThread: conversation == .direct)
            case .peer:
                PeerAssistantPage()
            case .family:
                FamilyPage(isOpenedFromThread: true)
            }
        }
        .sheet(item: $openedCall) { message in
            if let call = message.call {
                CallTranscriptSheet(call: call, sentAt: message.sentAt)
            }
        }
        .sheet(item: $selection) { selected in
            MessageSelectionSheet(text: selected.text)
        }
        .alert("Couldn't speak message", isPresented: Binding(
            get: { model.messageSpeech.failure != nil },
            set: { if !$0 { model.messageSpeech.clearFailure() } }
        )) {
            Button("OK") { model.messageSpeech.clearFailure() }
        } message: {
            Text(model.messageSpeech.failure ?? "")
        }
        .onDisappear { model.messageSpeech.stop() }
        .animation(Motion.fade, value: reacting?.id)
        .onChange(of: reacting?.id) { _, lifted in
            ThreadLog.note("message menu \(lifted == nil ? "closed" : "open")")
        }
        .onChange(of: background, initial: true) { _, background in
            ThreadLog.note("chat drawn on \(background.rawValue)")
        }
        .task(id: thread.lastMessageId) {
            if history == nil { await model.room.markRead(conversation) }
        }
        .onChange(of: model.room.thread(conversation).messages.last?.bubbleId) {
            if model.room.thread(conversation).messages.last?.author == model.room.me?.person {
                historyGeneration += 1
                history = nil
            }
        }
        // Again whenever what is asked changes, or the pages read for it bring more.
        .task(id: "\(search.isOpen) \(model.room.thread(conversation).lastMessageId ?? "") \(search.filter.rawValue) \(search.query) \(search.olderRequest)") {
            guard search.isOpen else {
                return
            }
            let recent = model.room.thread(conversation)
            await search.search(recent.messages, heard: VoiceNoteTranscripts.shared.known,
                                hasOlder: recent.hasOlder) { before in
                try await model.room.historyPage(conversation, before: before)
            }
        }
        .onChange(of: search.shows) {
            listState.found = nil
            show(search.currentMatch, in: thread)
        }
    }

    /// Search takes the composer's place, keeping its draft and attachments alive without
    /// letting their height leave an invisible gap above the keyboard.
    private var bottomBar: some View {
        VStack(spacing: 6) {
            if model.messageSpeech.messageID != nil {
                HStack(spacing: 10) {
                    if model.messageSpeech.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "speaker.wave.2.fill")
                    }
                    Text(model.messageSpeech.isLoading ? "Preparing audio…" : "\(model.messageSpeech.voiceName) is speaking")
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button("Stop", systemImage: "stop.fill") { model.messageSpeech.stop() }
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("Stop speaking")
                        .accessibilityIdentifier("message.stop-speaking")
                }
                .padding(.leading, 16)
                .padding(.trailing, 4)
                .background(.regularMaterial, in: Capsule())
                .padding(.horizontal, 16)
            }
            composerBar
        }
    }

    private var composerBar: some View {
        ZStack(alignment: .bottom) {
            RoomComposer(conversation: conversation, replyingTo: $replyingTo, asking: $asking) {
                search.open()
            }
            .opacity(search.isOpen ? 0 : 1)
            .frame(height: search.isOpen ? 0 : nil)
            .allowsHitTesting(!search.isOpen)
            .accessibilityHidden(search.isOpen)
            if search.isOpen {
                ThreadSearchBar(search: search) {
                    search.close()
                    listState.found = nil
                }
            }
        }
    }

    /// Only the small results card covers the thread. It stays clear of the composer,
    /// leaves most of the available chat readable, and never draws an empty search cover.
    @ViewBuilder
    private var searchResults: some View {
        if search.isOpen, search.isListShown, search.hasQuery {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ThreadSearchResults(search: search, maximumHeight: min(280, max(0, geometry.size.height * 0.5 - 8))) { index in
                        search.pick(index)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    /// Brings a search's match into view: the answers round it parsed first, so it lands
    /// whole in one move, and it glows a moment once there.
    private func show(_ match: ThreadSearch.Match?, in thread: RoomThread) {
        guard let match else {
            return
        }
        let shows = search.shows
        Task {
            var shown = thread
            if !shown.messages.contains(where: { $0.id == match.messageId }), let rev = match.rev,
               let page = try? await model.room.historyPage(conversation, before: rev + 1) {
                guard search.isOpen, search.shows == shows else { return }
                shown = RoomThread(conversation)
                shown.load(page)
                shown.boundHistory()
                historyGeneration += 1
                history = shown
            }
            let list = shown.messages
            if let index = list.firstIndex(where: { $0.id == match.messageId }) {
                let near = Array(list[max(0, index - 12)...min(list.count - 1, index + 12)])
                await MarkdownDocuments.prepare(near, participants: model.room.participants, me: model.room.me, style: readingStyle)
            }
            // Only the newest ask moves the thread, however long its parsing took.
            guard search.isOpen, search.shows == shows else {
                return
            }
            threadJump = ThreadJump(messageId: match.messageId, count: shows)
            listState.found = match.messageId
            try? await Task.sleep(for: .seconds(3))
            if search.shows == shows {
                listState.found = nil
            }
        }
    }

    private var title: String {
        conversation == .family ? "The Fam" : model.assistantName
    }

    /// What the conversation is drawn on: the family room's own background while either
    /// person has set its appearance to Custom, the same on both phones, and otherwise
    /// this phone's own.
    private var background: ChatBackground {
        let shared = conversation == .family ? model.room.familyLook?.sharedBackground : nil
        return shared ?? .rainbow
    }

    /// The night's navy is dark whatever the iPhone's mode, so the room on it is too.
    private var backgroundScheme: ColorScheme? {
        ThemeSelection.shared.palette(for: colorScheme) == nil && background == .night ? .dark : nil
    }

    /// Everyone's faces in one circle, or the assistant's photo or emoji in its gold ring,
    /// over the name in a glass pill that says it opens.
    private var header: some View {
        // Kept to the height of the bar it sits in.
        VStack(spacing: 1) {
            if conversation == .family {
                FamilyAvatar(participants: model.room.participants, size: 28, ring: model.room.familyLook?.ring)
            } else {
                AssistantAvatar(
                    emoji: model.identity?.emoji,
                    photo: model.assistantPhoto,
                    size: 27,
                    isBreathing: !model.room.typing(in: .direct).isEmpty,
                    ring: model.assistantRing
                )
            }
            HStack(spacing: 2) {
                // "Connecting…" in place of the name while the link comes back.
                Text(model.connectionNotice.isShown ? model.connection.state.comingBackTitle ?? title : title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Image(systemName: "chevron.forward")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Palette.secondaryText)
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .padding(.vertical, 2)
            .rainbowGlass(in: Capsule())
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// The menu's way to ask this phone's assistant about `message`, where it offers one.
    private func askAction(about message: RoomMessage) -> (() -> Void)? {
        guard canAsk(about: message) else {
            return nil
        }
        return {
            replyingTo = message
            asking = model.assistantName
            reacting = nil
        }
    }

    /// Asking this phone's assistant about a message is for the family room, where the
    /// assistant answers only when it is mentioned. In its own thread a reply already asks
    /// it, and so does a reply to its own message.
    private func canAsk(about message: RoomMessage) -> Bool {
        conversation == .family && message.author != model.room.me?.assistant
    }

    /// A tapped @mention: an assistant's opens their page. A person's only shows who it is.
    private func openPage(of mentioned: String) {
        guard model.room.participant(mentioned)?.kind == .assistant else {
            return
        }
        assistantPage = mentioned == model.room.me?.assistant ? .own : .peer
    }

    /// The thread's list, with SwiftUI keeping its rows clear of the bars and composer.
    private func messages(_ thread: RoomThread) -> some View {
        let list = thread.messages
        let me = model.room.me
        #if DEBUG
        let start = CACurrentMediaTime()
        #endif
        let rows = ThreadRow.rows(
            of: thread,
            me: me,
            assistants: assistantIds,
            typing: model.room.typing(in: conversation),
            activity: model.room.shownStep(in: conversation),
            readying: model.room.readying(in: conversation),
            shared: model.shares.waiting(in: conversation),
            isConnected: model.connection.state == .connected,
            lifted: reacting.flatMap { $0.id == liftShown ? $0.id : nil }
        )
        #if DEBUG
        ThreadFlingLog.shared.passed("rows", since: start)
        #endif
        // What this phone sends is followed from wherever the person was. By bubble, so a
        // reply kept after it streamed is no new message.
        let newestOwnBubble = list.last.flatMap { $0.author == me?.person ? $0.bubbleId : nil }
        return ThreadList(
            conversation: conversation,
            rows: rows,
            newestOwnBubble: newestOwnBubble,
            actions: threadActions,
            loadOlder: {
                let generation = historyGeneration
                if let older = await model.room.olderWindow(than: history ?? model.room.thread(conversation)),
                   generation == historyGeneration {
                    history = older
                }
            },
            state: listState,
            jump: threadJump,
            preparation: ThreadPreparation(
                isReady: { visible in
                    MarkdownDocuments.areReady(visible, participants: model.room.participants, me: model.room.me, style: readingStyle)
                },
                prepare: { visible in
                    await MarkdownDocuments.prepare(visible, participants: model.room.participants, me: model.room.me, style: readingStyle)
                }
            ),
            returnToLatest: history == nil ? nil : {
                historyGeneration += 1
                history = nil
                if let newest = model.room.thread(conversation).lastMessageId {
                    threadJump = ThreadJump(messageId: newest, count: (threadJump?.count ?? 0) + 1)
                }
            }
        )
        // Every finished answer here parsed before it scrolls into view, so its bubble is
        // built at its full height (MarkdownDocuments). Again whenever messages come or go.
        .task(id: Preparation(ids: list.map(\.id), style: readingStyle)) {
            await MarkdownDocuments.prepare(list, participants: model.room.participants, me: model.room.me, style: readingStyle)
        }
    }

    /// What the thread's rows do, all of which comes back to this screen.
    private var threadActions: ThreadActions {
        ThreadActions(
            onReact: { message, frame, point in
                reactingFrame = frame
                reactingPoint = point
                reacting = message
            },
            onReply: { message in
                replyingTo = message
            },
            onOpenMedia: { media in
                zoomedMedia = media.id
                viewing = media
            },
            onRetry: { message in
                Task {
                    await model.room.retry(message.id, in: conversation)
                }
            },
            onOpenCall: { message in
                openedCall = message
            }
        )
    }

    /// The room's assistants, the only ones whose carts replace one another's.
    private var assistantIds: Set<String> {
        Set(model.room.participants.filter { $0.kind == .assistant }.map(\.id))
    }

    /// Which carts in the thread a newer one has replaced, worked out once for all of them.
    private func cartReplacements(in list: [RoomMessage]) -> CartReplacements {
        CartReplacements(messages: list, assistants: assistantIds)
    }

    /// The pressed message drawn again over the blur, the same as it sits in the thread,
    /// with the reactions it has now.
    @ViewBuilder
    private func liftedBubble(_ pressed: RoomMessage, in thread: RoomThread) -> some View {
        let list = thread.messages
        if let index = list.firstIndex(where: { $0.id == pressed.id }) {
            RoomBubble(
                message: list[index],
                placement: BubblePlacement.placements(for: list)[index],
                conversation: conversation,
                repliedTo: list[index].replyTo.flatMap { id in list.first { $0.id == id } },
                replacedCarts: cartReplacements(in: list).carts(replacedIn: pressed.id),
                onReact: { _, _ in },
                onReply: {},
                onOpenMedia: { _ in },
                onRetry: {},
                offersFollowups: false
            )
            .allowsHitTesting(false)
        }
    }

    private func react(to message: RoomMessage, with emoji: String) {
        reacting = nil
        let current = message.reactions.first { $0.author == model.room.me?.person }?.emoji
        Task {
            await model.room.react(to: message.id, with: current == emoji ? nil : emoji, in: conversation)
        }
    }
}


