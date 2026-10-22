// Chats, where the app opens: the family room and this phone's own thread with its
// assistant as two big pinned faces, the way Messages pins a conversation, and what was
// shared in either in one strip underneath, all of it or one conversation's. Between them,
// once the two assistants have passed each other anything, a row opens the Corey & Denise
// group both parents watch (PairView). Sharing where this iPhone is runs in the background
// with nothing here: Location in Settings, and the chat it was shared in, say whether it
// is on.
//
// Under it floats the glass tab bar, Chats and Settings, both always there. Your own face
// at the top left opens Settings too, and the phone at the top right calls your assistant.
// A conversation opened from Chats has the screen to itself, with no tab bar, as in
// Telegram. While a call goes on with its screen left, the call bar sits over the top of
// all of it.
//
// As the app opens, the page settles in and the tab bar rises, the pins rise one after
// another, and the Today card, the assistants' row and what was shared arrive last, all
// within about a third of a second. A conversation slides in and out, as in Telegram: zoomed out of its pinned face,
// the open chat's own page showed as a white card over the face as it closed back into it.
// A picture zooms out of its tile. With Reduce Motion everything only fades.

import SwiftUI
import UIKit

struct InboxView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion
    @State private var viewing: RoomMedia?
    /// Search from what was shared (SharedSearchView), and what was picked in it.
    @State private var isSearchingShared = false
    @State private var pickedShared: SharedMedia?
    /// The picture the viewer shows now, which it closes back into.
    @State private var zoomedMedia: String?
    /// Whether Chats has made its entrance, once, as the app opens.
    @State private var hasEntered = false
    /// Whether the Corey & Denise group is open over Chats, from its row.
    @State private var isPairOpen = false
    @Namespace private var zoom

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            Tab("Chats", systemImage: "bubble.left.and.bubble.right.fill", value: AppTab.chats) {
                chats
                    // On the tab's own content, outside its NavigationStack: iOS 26 never
                    // hands the tab bar a choice made inside the stack, the open chat's or
                    // Chats' own, so a chat showed the bar under its composer. The bar rises
                    // in as the page settles and is gone while a chat is open.
                    .toolbar(hasEntered && model.path.isEmpty && !isPairOpen ? .visible : .hidden, for: .tabBar)
            }
            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView()
                    .toolbar(.visible, for: .tabBar)
            }
        }
        // Always both tabs: the owner wants the bar never to fold into one button.
        .tabBarMinimizeBehavior(.never)
        .onChange(of: model.path) { old, new in
            if old.isEmpty, !new.isEmpty {
                ChatTiming.opened()
                // A conversation opened from anywhere shows alone, as it does over Chats.
                isPairOpen = false
            }
            #if DEBUG
            DemoBackTransitionObservation.shared.pathChanged(from: old, to: new)
            #endif
        }
        // Over the tabs, so the call bar shows over a conversation or Settings too.
        .callBar(barredCall.map { call in
            CallBar(state: call.state, level: call.level) {
                model.isCallShown = true
            }
        })
        // Over the tabs, so a widget, Siri or a Call button can bring it up over a
        // conversation or Settings as well.
        .fullScreenCover(item: shownCall) { call in
            CallView(call: call)
        }
        .onAppear {
            withAnimation(reduceMotion ? Motion.fade : Motion.settle) {
                hasEntered = true
            }
        }
    }

    private var chats: some View {
        @Bindable var model = model
        return NavigationStack(path: $model.path) {
            ZStack {
                MeshBackground()
                    .opacity(hasEntered ? 1 : 0)
                    .scaleEffect(hasEntered || reduceMotion ? 1 : 1.06)
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ConnectionBanner()
                        if model.room.isAvailable == false {
                            ContentUnavailableView(
                                "Not set up yet",
                                systemImage: "bubble.left.and.exclamationmark.bubble.right",
                                description: Text("\(model.assistantName)'s gateway has no family room yet.")
                            )
                            .padding(.top, 60)
                        } else {
                            TodayCardView()
                                .modifier(Entering(order: RoomConversation.allCases.count, hasEntered: hasEntered))
                            // The two faces stay far enough apart that the lines over them
                            // never touch.
                            HStack(alignment: .top, spacing: 40) {
                                ForEach(Array(RoomConversation.allCases.enumerated()), id: \.element) { order, conversation in
                                    PinnedConversation(conversation: conversation)
                                        .modifier(Entering(order: order, hasEntered: hasEntered))
                                }
                            }
                            .frame(maxWidth: .infinity)
                            // Room for the bubble that sits over a face.
                            .padding(.top, 44)
                            if model.room.pairLastAt != nil || !model.pairLine.entries.isEmpty {
                                PairRow { isPairOpen = true }
                                    .padding(.horizontal, 16)
                                    .modifier(Entering(order: RoomConversation.allCases.count, hasEntered: hasEntered))
                            }
                            SharedStrip(onOpen: { open($0) }, onSearch: { isSearchingShared = true })
                                .modifier(Entering(order: RoomConversation.allCases.count, hasEntered: hasEntered))
                        }
                    }
                    // A clear gap above the floating tab bar at the end of the list.
                    .padding(.bottom, 48)
                    .animation(Motion.arrive(reduced: reduceMotion), value: model.today.glance)
                }
                .refreshable {
                    await model.room.refresh()
                }
            }
            .environment(\.mediaZoom, zoom)
            // "Connecting…" in place of the title while the link comes back, as Telegram's
            // title says it, so nothing moves or flashes over the list.
            .navigationTitle(model.connectionNotice.isShown ? model.connection.state.comingBackTitle ?? "Chats" : "Chats")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                // On a glass circle like the Call button, so it turns into and out of a
                // chat's back button glass to glass, with no white square between.
                ToolbarItem(placement: .topBarLeading) {
                    settingsButton
                }
                ToolbarItem(placement: .topBarTrailing) {
                    CallButton()
                }
            }
            .navigationDestination(for: RoomConversation.self) { conversation in
                RoomView(conversation: conversation)
            }
            .navigationDestination(isPresented: $isPairOpen) {
                PairView()
            }
            .fullScreenCover(item: $viewing) { media in
                MediaViewer(media: media) { shown in
                    zoomedMedia = shown.id
                }
                .zoomTransition(from: zoomedMedia ?? media.id, in: zoom)
            }
            // What was picked opens once the sheet has gone, as only one can be up at a time.
            .sheet(isPresented: $isSearchingShared, onDismiss: {
                if let picked = pickedShared {
                    pickedShared = nil
                    open(picked)
                }
            }) {
                SharedSearchView(picked: $pickedShared)
            }
        }
    }

    /// The call while its screen is up. The cover keeps the call it shows as it goes, so a
    /// call that has ended still says so as its screen slides away.
    private var shownCall: Binding<TalkViewModel?> {
        Binding(
            get: { model.isCallShown ? model.call : nil },
            set: { call in
                if call == nil {
                    model.isCallShown = false
                }
            }
        )
    }

    /// The call while it carries on with its screen left.
    private var barredCall: TalkViewModel? {
        model.isCallShown ? nil : model.call
    }

    /// This phone's own person, the way the room draws them.
    private var me: RoomParticipant? {
        model.room.me.flatMap { model.room.participant($0.person) }
    }

    private var settingsButton: some View {
        Button {
            model.tab = .settings
        } label: {
            if let me {
                ParticipantAvatar(participant: me, size: 36)
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Palette.highlight)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
    }

    /// A photo or a video opens full screen; a voice note or a file opens where it was sent.
    private func open(_ item: SharedMedia) {
        switch item.media.kind {
        case .photo, .video:
            zoomedMedia = item.media.id
            viewing = item.media
        case .voice, .file:
            model.path.append(item.conversation)
        }
    }
}

/// One piece of Chats arriving as the app opens, `order`th in turn: up from a little below
/// and growing as it fades in, or only fading with Reduce Motion.
private struct Entering: ViewModifier {
    let order: Int
    let hasEntered: Bool

    @Environment(\.reducesMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(hasEntered ? 1 : 0)
            .scaleEffect(hasEntered || reduceMotion ? 1 : 0.94)
            .offset(y: hasEntered || reduceMotion ? 0 : 24)
            .animation(Motion.entrance(order, reduced: reduceMotion), value: hasEntered)
    }
}

/// One conversation as a big face, with an unread dot, and above the face either the
/// typing dots or, while there is something unread, its latest line.
///
/// It reads the conversation's summary, never its thread, so a reply streaming in there
/// does not redraw it.
private struct PinnedConversation: View {
    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion
    let conversation: RoomConversation

    private static let faceSize: CGFloat = 88

    var body: some View {
        let summary = model.room.summary(conversation)
        let unread = summary.unread
        let isTyping = summary.isTyping
        NavigationLink(value: conversation) {
            VStack(spacing: 8) {
                face
                    .shadow(color: Palette.shadow, radius: 12, y: 6)
                    .overlay(alignment: .topTrailing) {
                        if unread > 0 {
                            Circle()
                                .fill(Palette.highlight)
                                .frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                                .offset(x: -2, y: 2)
                        }
                    }
                    .overlay(alignment: .top) {
                        Group {
                            if isTyping {
                                TypingDots(color: Palette.secondaryText, dotSize: 6)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .rainbowGlass(in: Capsule())
                                    .transition(Motion.popTransition(reduced: reduceMotion))
                            } else if unread > 0, summary.latestId != nil {
                                RoomPreview(summary: summary, conversation: conversation)
                                    .font(.caption)
                                    .foregroundStyle(Palette.text)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .rainbowGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    // Wider than the face, and no wider than its words need.
                                    .frame(width: 120)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .transition(Motion.popTransition(reduced: reduceMotion))
                            }
                        }
                        // Above the face, overlapping its top a little.
                        .alignmentGuide(.top) { dimensions in dimensions[.bottom] - 14 }
                    }
                    .animation(Motion.arrive(reduced: reduceMotion), value: isTyping)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel(unread: unread, isTyping: isTyping))
        .accessibilityAddTraits(.isButton)
        // The motion film finds the pin by this, whatever its label says is unread.
        .accessibilityIdentifier("pin.\(conversation.rawValue)")
    }

    private var title: String {
        conversation == .family ? "The Fam" : model.assistantName
    }

    @ViewBuilder
    private var face: some View {
        switch conversation {
        case .family:
            FamilyAvatar(participants: model.room.participants, size: Self.faceSize, ring: model.room.familyLook?.ring)
        case .direct:
            AssistantAvatar(
                emoji: model.identity?.emoji,
                photo: model.assistantPhoto,
                size: Self.faceSize,
                isBreathing: model.room.summary(.direct).isTyping,
                ring: model.assistantRing
            )
        }
    }

    private func spokenLabel(unread: Int, isTyping: Bool) -> String {
        var parts = [title]
        if isTyping {
            parts.append("typing")
        }
        if unread > 0 {
            parts.append("\(unread) unread")
        }
        return parts.joined(separator: ", ")
    }
}

/// Photos, videos, voice notes and files from both conversations, newest first. It reads
/// only what the gateway has kept of them, so a reply streaming in does not redraw it. The
/// magnifying glass beside its title searches all of them (SharedSearchView).
private struct SharedStrip: View {
    @Environment(AppModel.self) private var model
    let onOpen: (SharedMedia) -> Void
    let onSearch: () -> Void

    /// Which conversation's things show: nil for both.
    @State private var showing: RoomConversation?

    var body: some View {
        let shown = SharedMedia.latest(
            in: RoomConversation.allCases.filter { showing == nil || $0 == showing }.map { ($0, model.room.kept($0).messages) },
            limit: 24
        )
        let hasAny = showing != nil || !shown.isEmpty
        if hasAny {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Shared with you")
                        .font(.footnote.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(Palette.secondaryText)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button(action: onSearch) {
                        Image(systemName: "magnifyingglass")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Palette.highlight)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Search what was shared")
                    .accessibilityIdentifier("shared.search")
                }
                .padding(.horizontal, 20)
                GlassSegmentedControl(choices: [nil, .family, .direct], selection: $showing) { choice in
                    switch choice {
                    case nil:
                        return "All"
                    case .family?:
                        return "Fam"
                    case .direct?:
                        return model.assistantName
                    }
                }
                .padding(.horizontal, 16)
                if shown.isEmpty {
                    Text("Nothing shared here yet.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondaryText)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 12) {
                            ForEach(shown) { item in
                                Button {
                                    onOpen(item)
                                } label: {
                                    SharedTile(item: item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
    }
}

/// One thing shared: a photo as itself, coming into focus as it loads, anything else as a
/// glass card saying what it is. A photo or a video zooms into the viewer out of its tile.
private struct SharedTile: View {
    @Environment(AppModel.self) private var model
    @Environment(\.reducesMotion) private var reduceMotion
    @Environment(\.mediaZoom) private var zoom
    let item: SharedMedia

    @State private var thumbnail: UIImage?

    /// Each thumbnail decoded once, so switching what Shared shows or scrolling back
    /// draws it at once rather than decoding the photo again.
    private static let thumbnails = NSCache<NSString, UIImage>()

    /// The strip's height, and a card's width, grow with the text, so nothing in a tile is
    /// clipped at the largest sizes.
    @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = 112
    @ScaledMetric(relativeTo: .subheadline) private var cardWidth: CGFloat = 150

    var body: some View {
        Group {
            if item.media.kind == .photo {
                photo
            } else {
                card
            }
        }
        .zoomSource(item.media.id, in: item.media.kind.isVisual ? zoom : nil)
        .accessibilityElement(children: .combine)
    }

    private var photo: some View {
        ZStack {
            Rectangle()
                .fill(Palette.surface)
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .transition(Motion.blurUpTransition(reduced: reduceMotion))
            } else {
                Image(systemName: RoomMediaSymbol.name(for: .photo))
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .frame(width: height, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(Motion.reveal(reduced: reduceMotion), value: thumbnail == nil)
        .shadow(color: Palette.shadow, radius: 8, y: 4)
        .accessibilityLabel("Photo from \(authorName)")
        .task(id: item.media.id) {
            let key = "\(item.media.id)@\(Int(height))" as NSString
            if let kept = Self.thumbnails.object(forKey: key) {
                thumbnail = kept
                return
            }
            guard let file = try? await model.media.url(for: item.media) else {
                return
            }
            // Drawn small, so it is decoded small: a photo from the camera is many times this.
            let made = await UIImage(contentsOfFile: file.path)?
                .byPreparingThumbnail(ofSize: CGSize(width: height * 3, height: height * 3))
            if let made {
                Self.thumbnails.setObject(made, forKey: key)
            }
            thumbnail = made
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: RoomMediaSymbol.name(for: item.media.kind))
                .font(.title2)
                .foregroundStyle(Palette.highlight)
            Spacer(minLength: 0)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.text)
                .lineLimit(2)
            Text(detail)
                .font(.caption)
                .foregroundStyle(Palette.secondaryText)
                .lineLimit(1)
        }
        .padding(12)
        .frame(width: cardWidth, height: height, alignment: .leading)
        .rainbowGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var authorName: String {
        model.room.participant(item.author)?.name ?? "someone"
    }

    private var title: String {
        switch item.media.kind {
        case .file:
            return item.media.name ?? "File"
        case .voice, .photo, .video:
            return authorName
        }
    }

    private var detail: String {
        switch item.media.kind {
        case .voice:
            return "Voice note \u{00B7} " + VoiceNoteGesture.clock(milliseconds: item.media.durationMs ?? 0)
        case .video:
            return "Video"
        case .file:
            return "From \(authorName)"
        case .photo:
            return "Photo"
        }
    }
}

/// A conversation's latest line: words, or an icon for what was sent, after the speaker's
/// name in the family room. Whoever shows it sets its font and colour.
struct RoomPreview: View {
    @Environment(AppModel.self) private var model
    let summary: ConversationSummary
    let conversation: RoomConversation

    var body: some View {
        HStack(spacing: 4) {
            if conversation == .family, let author = summary.latestAuthor, author != model.room.me?.person,
               let name = model.room.participant(author)?.name {
                Text("\(name):")
                    .fontWeight(.semibold)
            }
            if let symbol = summary.previewSymbol {
                Image(systemName: symbol)
                if !summary.preview.isEmpty {
                    Text(summary.preview)
                }
            } else {
                Text(summary.preview)
            }
        }
    }
}
