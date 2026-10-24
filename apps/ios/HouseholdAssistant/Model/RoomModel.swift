// The phone's half of the household-app channel: the family room and this phone's own
// thread with its assistant, kept in step with the gateway.
//
// The gateway's record is the truth. The phone reads the newest page of each
// conversation when the link comes up, then follows every change by revision, and a
// `changed` event says when there is something to follow. What this phone sends shows
// at once and settles when the gateway keeps it. Every message is signed with this
// phone's device key first: the other gateway believes nothing about its owner's family
// that the owner's phone did not sign, and this gateway starts its owner's turn in the
// direct thread only from a message a paired phone signed. An answer to an approval card
// is signed the same way, since only this phone may say yes for its person, and so is a
// map this phone shares and its person's answer to a reminder by place that would watch
// them.

import Foundation
import Observation

@MainActor
@Observable
final class RoomModel {
    private(set) var family = RoomThread(.family)
    private(set) var direct = RoomThread(.direct)
    /// What the gateway has kept of each conversation, for Chats' shared strip and the
    /// widgets, which show nothing else. Replaced only when that changes, so neither is
    /// redrawn by a reply streaming in or a step of the assistant's work.
    private(set) var keptFamily = RoomThread(.family)
    private(set) var keptDirect = RoomThread(.direct)
    /// What each conversation's pin on Chats shows, replaced only when that changes.
    private(set) var familySummary = ConversationSummary.empty
    private(set) var directSummary = ConversationSummary.empty
    private(set) var participants: [RoomParticipant] = []
    /// Who this phone is to the gateway. Nil until a page has said.
    private(set) var me: RoomSelf?
    /// The other household's assistant, for her page in the family room. The last one a
    /// sync page carried, so a page without her does not blank it.
    private(set) var peerAssistant: PeerAssistant?
    /// The family room's own photo, which its face shows in place of everyone's faces.
    private(set) var familyAvatar: RoomMedia?
    /// The family room's look, the same on both phones. Nil until anyone changes it.
    private(set) var familyLook: FamilyLook?
    /// When the two assistants' direct line last moved, in milliseconds, from the pages and
    /// the plugin's `pair` event, for the family room's quiet marker. Nil before its first step.
    private(set) var pairLastAt: Int?
    /// The newest revision this phone has followed.
    private(set) var rev = 0
    /// False when the gateway this phone pairs with has no household-app channel,
    /// nil until it has been asked.
    private(set) var isAvailable: Bool?
    private(set) var errorText: String?
    /// Checklist items this phone ticked or unticked, over what the assistant's card said.
    private(set) var ticks: [ChecklistTick: Bool] = [:]
    /// Approval cards this phone answered, by message id, shown at once until the
    /// gateway says how each ended.
    private(set) var answers: [String: RoomApproval.Outcome] = [:]
    /// Why an answer to a card did not go through, by its message id, in the gateway's words.
    private(set) var approvalRefusals: [String: String] = [:]
    /// Why an answer to a reminder by place did not go through, by its message id.
    private(set) var placeRefusals: [String: String] = [:]
    /// What this phone did with each message card, by the id of the assistant's message
    /// that holds it, so a card scrolled away and back still says it was sent. Kept on
    /// this phone only: the gateway never hears who a text went to.
    var messageCards: [String: MessageCardState] = [:]

    @ObservationIgnored private let connection: GatewayConnection
    /// What this phone keeps of each conversation, so a thread opens at once and offline;
    /// nil where nothing is kept.
    @ObservationIgnored private let archive: RoomArchive?
    /// Each conversation as kept, written to the archive a moment after it changes.
    @ObservationIgnored private var kept: [RoomConversation: RoomArchive.Kept] = [:]
    @ObservationIgnored private var keeping: Task<Void, Never>?
    /// The archive forgotten again once the writes under way at a reset have ended, which
    /// every write after the reset waits for.
    @ObservationIgnored private var forgetting: Task<Void, Never>?
    /// Whether a page from the gateway has been read since the last reset, after which a
    /// kept thread is not shown over it.
    @ObservationIgnored private var hasReadPage = false
    @ObservationIgnored private let sign: (String) throws -> String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let makeId: () -> String
    @ObservationIgnored private var sessionKeys: [RoomConversation: String] = [:]
    /// The session this phone's person's own family-room turns run in, apart from the room's
    /// shared one, so their assistant's replies to them stream from there. Nil from a gateway
    /// that runs them in the shared one.
    @ObservationIgnored private var ownersFamilySession: String?
    @ObservationIgnored private var catchingUp: Task<Void, Never>?
    @ObservationIgnored private var catchUpAgain = false
    /// A streaming reply's words not yet in their thread, by conversation, in order.
    @ObservationIgnored private var waitingWords: [RoomConversation: [StreamedWords]] = [:]
    @ObservationIgnored private var flushingWords: Task<Void, Never>?

    private struct StreamedWords {
        let runId: String
        let author: String
        let text: String
        let replace: Bool
    }
    /// Messages already signed, by id, so a retry sends exactly what was signed.
    @ObservationIgnored private var outgoing: [String: RoomOutgoing] = [:]
    /// Messages whose attachments never finished uploading, by id.
    @ObservationIgnored private var drafts: [String: Draft] = [:]
    /// Messages said while the link was down, in the order they were said, which go out by
    /// themselves once a page shows the link is back (refresh).
    @ObservationIgnored private var waitingForLink: [(id: String, conversation: RoomConversation)] = []
    @ObservationIgnored private var isSendingWaiting = false
    /// Each waiting message as it was said, kept in the archive until it goes out.
    @ObservationIgnored private var waitingKept: [String: RoomArchive.Waiting] = [:]
    /// The last write of what waits, so the writes land in the order they were made.
    @ObservationIgnored private var waitingWrite: Task<Void, Never>?
    /// Observed, so a typing bubble shows the moment its event arrives.
    private var typingUntil: [RoomConversation: [String: Date]] = [:]
    /// Observed, so Talk says what the assistant is doing the moment a tool starts. The
    /// typing bubble follows `steps`.
    private var activities: [RoomConversation: AssistantActivity] = [:]
    /// The tool call each activity belongs to, so another call's result does not end it.
    @ObservationIgnored private var toolCalls: [RoomConversation: String] = [:]
    /// What the working line in each conversation's typing bubble says: the assistant's
    /// steps, each held long enough to read. Observed, so the line follows it.
    private var steps: [RoomConversation: ToolSteps] = [:]
    /// The wait for each conversation's shown step to give way to the next.
    @ObservationIgnored private var stepping: [RoomConversation: Task<Void, Never>] = [:]
    /// Replies that have finished streaming whose words are being made ready to draw, by
    /// message id. Observed, so the thread shows each whole the moment it is ready.
    private var readying: [RoomConversation: Set<String>] = [:]
    @ObservationIgnored private var lastRead: [RoomConversation: String] = [:]
    /// When this phone last said its person is typing, by conversation, while they are.
    @ObservationIgnored private var saidTypingAt: [RoomConversation: Date] = [:]
    @ObservationIgnored private var replyWaiters: [UUID: (afterRev: Int, continuation: CheckedContinuation<String, Error>)] = [:]
    /// Called when who is in the room, or a face, changes: the notifications' faces follow.
    @ObservationIgnored var onParticipantsChanged: (() -> Void)?
    /// Called when the gateway keeps a message this phone sent: the Share Sheet's
    /// suggestions follow the conversations the person writes in.
    @ObservationIgnored var onSent: ((RoomConversation) -> Void)?
    /// Called with the messages a page brings, before they are shown, so whatever a bubble
    /// draws is ready and it has its full height from its first frame.
    @ObservationIgnored var prepare: (([RoomMessage]) async -> Void)?

    static let typingSeconds: TimeInterval = 30
    /// How often a person still typing says so again, well inside `typingSeconds`.
    static let typingRefreshSeconds: TimeInterval = 10
    /// How long a streaming reply's words wait for the pieces after them, so the thread
    /// changes at most about twenty times a second however fast they come.
    static let streamInterval: Duration = .milliseconds(50)
    static let pageBudget = 20
    nonisolated static let replySeconds: TimeInterval = 120
    /// The gateway refused a message this phone sent; the reason is the gateway's.
    static let sendFailureCode = "ROOM_SEND_REFUSED"
    /// A streamed reply the gateway stopped, whether it broke or someone aborted it.
    static let unfinishedReplyReason = "The assistant could not finish that reply."

    init(
        connection: GatewayConnection,
        sign: @escaping (String) throws -> String,
        archive: RoomArchive? = nil,
        now: @escaping () -> Date = Date.init,
        makeId: @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.connection = connection
        self.archive = archive
        self.sign = sign
        self.now = now
        self.makeId = makeId
    }

    func thread(_ conversation: RoomConversation) -> RoomThread {
        conversation == .family ? family : direct
    }

    /// What the gateway has kept of a conversation (`RoomThread.kept`).
    func kept(_ conversation: RoomConversation) -> RoomThread {
        conversation == .family ? keptFamily : keptDirect
    }

    func summary(_ conversation: RoomConversation) -> ConversationSummary {
        conversation == .family ? familySummary : directSummary
    }

    func participant(_ id: String) -> RoomParticipant? {
        participants.first { $0.id == id }
    }

    /// Everyone in the room's name by their id, for words that name them.
    var names: [String: String] {
        Dictionary(participants.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    /// What this phone's assistant's run is busy with in a conversation while a tool
    /// runs. Nil while it thinks, and once the run is over.
    func activity(in conversation: RoomConversation) -> AssistantActivity? {
        activities[conversation]
    }

    /// What the working line in a conversation's typing bubble says: the step this phone's
    /// assistant is on, or one it has left that is still held long enough to read. Nil for
    /// the typing dots. Talk follows `activity(in:)` itself, at once.
    func shownStep(in conversation: RoomConversation) -> AssistantActivity? {
        steps[conversation]?.shown
    }

    /// The replies in a conversation that have finished streaming and are still being made
    /// ready to draw, by message id, which the thread shows once they are.
    func readying(in conversation: RoomConversation) -> Set<String> {
        readying[conversation] ?? []
    }

    /// Who is typing in a conversation now, sorted.
    func typing(in conversation: RoomConversation) -> [String] {
        let moment = now()
        return (typingUntil[conversation] ?? [:]).filter { $0.value > moment }.map(\.key).sorted()
    }

    // MARK: - Reading

    /// Each conversation as this phone kept it, shown before the gateway answers and when
    /// it cannot, read and decoded away from the main actor. A page from the gateway that
    /// came first is not covered over.
    func restore() async {
        guard let archive else {
            return
        }
        let (read, waiting) = await Task.detached(priority: .userInitiated) {
            let read = RoomConversation.allCases.compactMap { conversation -> KeptConversation? in
                guard let kept = archive.read(conversation), let page = try? kept.page.decoded(as: RoomHistoryPage.self) else {
                    return nil
                }
                let changes = kept.changes.compactMap { try? $0.decoded(as: RoomEntry.self) }
                return KeptConversation(conversation: conversation, kept: kept, page: page, changes: changes)
            }
            return (read, archive.readWaiting())
        }.value
        if !hasReadPage {
            // Who is in the room, from a kept page that says, before the threads are drawn.
            if let page = read.map(\.page).first(where: { !$0.participants.isEmpty }) {
                orient(participants: page.participants, me: page.me, sessionKeys: page.sessionKeys, ownersFamilySession: page.ownersFamilySession, familyAvatar: page.familyAvatar, familyLook: page.familyLook, pair: page.pair)
            }
            for found in read {
                kept[found.conversation] = found.kept
                update(found.conversation) { thread in
                    thread.load(found.page)
                    for entry in found.changes {
                        thread.apply(entry)
                    }
                }
            }
        }
        restoreWaiting(waiting)
    }

    /// What waited for the link when the app last closed, back at the end of its threads,
    /// waiting still, to go out once the link is back.
    private func restoreWaiting(_ waiting: [RoomArchive.Waiting]) {
        for message in waiting where waitingKept[message.id] == nil {
            guard !thread(message.conversation).messages.contains(where: { $0.id == message.id }) else {
                continue
            }
            update(message.conversation) {
                $0.addPending(RoomMessage(
                    id: message.id,
                    author: message.author,
                    text: message.text,
                    media: message.attachments.enumerated().map { index, attachment in
                        attachment.media(id: RoomMedia.pendingPrefix + String(index))
                    },
                    replyTo: message.replyTo,
                    sentAt: Date(timeIntervalSince1970: Double(message.at) / 1000),
                    status: .waiting
                ))
            }
            drafts[message.id] = Draft(
                text: message.text, replyTo: message.replyTo, attachments: message.attachments, location: nil, at: message.at, isCall: false
            )
            waitingKept[message.id] = message
            waitingForLink.append((message.id, message.conversation))
        }
    }

    /// One conversation read back from the archive.
    private struct KeptConversation: Sendable {
        let conversation: RoomConversation
        let kept: RoomArchive.Kept
        let page: RoomHistoryPage
        let changes: [RoomEntry]
    }

    /// The newest page of each conversation, then every change since.
    func refresh() async {
        do {
            for conversation in RoomConversation.allCases {
                let answer = try await connection.roomNewestKept(conversation)
                let page = answer.model
                hasReadPage = true
                update(conversation) { $0.load(page) }
                keep(RoomArchive.Kept(page: answer.json), for: conversation)
                orient(participants: page.participants, me: page.me, sessionKeys: page.sessionKeys, ownersFamilySession: page.ownersFamilySession, familyAvatar: page.familyAvatar, familyLook: page.familyLook, pair: page.pair)
                let newest = max(rev, page.messages.map(\.rev).max() ?? 0)
                if newest != rev {
                    rev = newest
                }
            }
            if isAvailable != true {
                isAvailable = true
            }
            if errorText != nil {
                errorText = nil
            }
        } catch {
            note(error)
            return
        }
        followConversations()
        await catchUp()
        await sendWaiting()
    }

    /// The gateway streams the assistant's replies, and the steps of the tools its runs
    /// use, only to a connection that follows the session, and forgets that with each
    /// connection. Both conversations are followed, and the person's own session of the
    /// family room beside the room's: Talk speaks a reply as it streams and says which tool
    /// is running, and in either thread the typing bubble says it too. A gateway that
    /// refuses still sends every reply whole, so a refusal only costs the live view and is
    /// not shown.
    private func followConversations() {
        for key in RoomConversation.allCases.compactMap({ sessionKeys[$0] }) + [ownersFamilySession].compactMap({ $0 }) {
            Task {
                try? await connection.followSession(key)
            }
        }
    }

    /// Follows every change after `rev`. Calls that arrive while one is running are
    /// folded into one more pass after it, rather than racing it.
    func catchUp() async {
        if let running = catchingUp {
            catchUpAgain = true
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else {
                return
            }
            repeat {
                self.catchUpAgain = false
                await self.followPages()
            } while self.catchUpAgain
            // In the same step as the last look at `catchUpAgain`: a call that comes after
            // it starts a pass of its own, rather than waiting on one that is already over.
            self.catchingUp = nil
        }
        catchingUp = task
        await task.value
    }

    private func followPages() async {
        for _ in 0..<Self.pageBudget {
            do {
                let answer = try await connection.roomSyncKept(since: rev)
                let page = answer.model
                keep(changes: answer.json["entries"]?.arrayValue ?? [])
                orient(participants: page.participants, me: page.me, sessionKeys: page.sessionKeys, ownersFamilySession: page.ownersFamilySession, familyAvatar: page.familyAvatar, familyLook: page.familyLook, pair: page.pair)
                let arriving = page.entries.filter { $0.kind == .message }.map { RoomMessage($0) }
                if !arriving.isEmpty {
                    await prepare?(arriving)
                }
                if let peer = page.peerAssistant, peer != peerAssistant {
                    peerAssistant = peer
                }
                // Each conversation takes the page's entries in one change, so a burst
                // redraws its thread once.
                let newReplies = page.entries.filter { entry in
                    entry.roomConversation == .direct && entry.kind == .message
                        && entry.author == page.me.assistant
                        && !direct.messages.contains { $0.id == entry.id && $0.rev != nil }
                }
                for conversation in RoomConversation.allCases {
                    let entries = page.entries.filter { $0.roomConversation == conversation }
                    if !entries.isEmpty {
                        update(conversation) { thread in
                            for entry in entries {
                                thread.apply(entry)
                            }
                        }
                    }
                }
                for entry in newReplies {
                    answered(entry)
                }
                if page.rev > rev {
                    rev = page.rev
                }
                if isAvailable != true {
                    isAvailable = true
                }
                guard page.hasMore else {
                    return
                }
            } catch {
                note(error)
                return
            }
        }
    }

    func loadOlder(_ conversation: RoomConversation) async {
        await readOlder(conversation, isOnScreen: true)
    }

    /// The page before the oldest one here. One that goes on screen is made ready first;
    /// one read for a transcript is not drawn, so it is not.
    private func readOlder(_ conversation: RoomConversation, isOnScreen: Bool) async {
        guard thread(conversation).hasOlder, let oldest = thread(conversation).oldestRev else {
            return
        }
        do {
            let page = try await connection.roomHistory(conversation, before: oldest)
            if isOnScreen {
                await prepare?(page.messages.filter { $0.kind == .message }.map { RoomMessage($0) })
            }
            update(conversation) { $0.loadOlder(page) }
        } catch {
            note(error)
        }
    }

    /// Fills the bounded recent-history cache. Older history stays on the gateway and
    /// can be read one window at a time without growing the live thread indefinitely.
    func loadAll(_ conversation: RoomConversation) async {
        for _ in 0..<Self.pageBudget {
            guard !Task.isCancelled, thread(conversation).hasOlder else { return }
            let oldest = thread(conversation).oldestRev
            await readOlder(conversation, isOnScreen: false)
            guard thread(conversation).oldestRev != oldest else {
                return
            }
        }
    }

    /// Read-only paging for search and browsing. Never adds a page to the live thread.
    func historyPage(_ conversation: RoomConversation, before: Int) async throws -> RoomHistoryPage {
        try Task.checkCancellation()
        let page = try await connection.roomHistory(conversation, before: before)
        try Task.checkCancellation()
        return page
    }

    func olderWindow(than window: RoomThread) async -> RoomThread? {
        guard window.hasOlder, let before = window.oldestRev else { return nil }
        do {
            let page = try await historyPage(window.conversation, before: before)
            guard page.messages.contains(where: { $0.rev < before }) else { return nil }
            var older = window
            older.loadOlder(page)
            older.boundHistory(keepingNewest: false)
            return older
        } catch {
            if !Task.isCancelled { note(error) }
            return nil
        }
    }

    // MARK: - Saying

    /// Shows the message at once, uploads what it carries, signs it, and sends it.
    /// Nothing is sent before a page has said who this phone is.
    /// Answers whether the gateway kept it, for a sender with no room on screen.
    ///
    /// `key` names the message for good, as a hand-off from the Share Extension is named:
    /// sent again, it is the same message to the gateway, which keeps the first, and one
    /// this room already shows as kept is not sent or shown twice. `isCall` marks words said
    /// aloud on a call, for an answer made to be heard (RoomOutgoing). `waitsForLink`, for
    /// what the person sends from the composer, keeps a message said with no link waiting
    /// in its thread to go out by itself once the link is back, behind whatever already waits.
    /// Siri, a call and a share need their answer now, so theirs fail instead.
    @discardableResult
    func send(
        _ text: String,
        in conversation: RoomConversation,
        replyTo: String? = nil,
        attachments: [RoomAttachment] = [],
        location: SharedLocation? = nil,
        key: String? = nil,
        isCall: Bool = false,
        waitsForLink: Bool = false
    ) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty || location != nil, let author = me?.person else {
            return false
        }
        let id = (conversation == .family ? "m-" : "d-") + (key ?? makeId())
        if let known = thread(conversation).messages.first(where: { $0.id == id }) {
            return known.rev != nil
        }
        let at = Int((now().timeIntervalSince1970 * 1000).rounded())
        update(conversation) {
            $0.addPending(RoomMessage(
                id: id,
                author: author,
                text: trimmed,
                media: attachments.enumerated().map { index, attachment in attachment.media(id: RoomMedia.pendingPrefix + String(index)) },
                replyTo: replyTo,
                sentAt: Date(timeIntervalSince1970: Double(at) / 1000),
                status: .sending,
                location: location
            ))
        }
        drafts[id] = Draft(text: trimmed, replyTo: replyTo, attachments: attachments, location: location, at: at, isCall: isCall)
        let said = RoomArchive.Waiting(
            id: id, conversation: conversation, author: author, text: trimmed, replyTo: replyTo, at: at, attachments: attachments
        )
        if waitsForLink, !waitingForLink.isEmpty {
            update(conversation) { $0.wait(id: id) }
            startWaiting(said)
            if connection.state == .connected {
                await sendWaiting()
            }
            return thread(conversation).messages.contains { $0.id == id && $0.rev != nil }
        }
        let delivery = await deliver(id, in: conversation, waitsForLink: waitsForLink)
        if delivery == .waiting {
            startWaiting(said)
        }
        return delivery == .kept
    }

    /// Puts a message at the back of what waits for the link, and keeps it on the phone.
    private func startWaiting(_ said: RoomArchive.Waiting) {
        waitingForLink.append((said.id, said.conversation))
        waitingKept[said.id] = said
        writeWaiting()
    }

    /// Writes what waits, in order, away from the main actor, each write after the last.
    private func writeWaiting() {
        guard let archive else {
            return
        }
        let waiting = waitingForLink.compactMap { waitingKept[$0.id] }
        let previous = waitingWrite
        waitingWrite = Task.detached(priority: .utility) {
            await previous?.value
            archive.writeWaiting(waiting)
        }
    }

    /// Shares where this phone is as a map, once or live, shown at once like any message.
    /// Answers the map's message id and time once the gateway has kept it, which is when a
    /// live one may start moving.
    func share(_ location: SharedLocation, in conversation: RoomConversation) async -> (id: String, at: Int)? {
        let key = makeId()
        guard await send("", in: conversation, location: location, key: key) else {
            return nil
        }
        let id = (conversation == .family ? "m-" : "d-") + key
        return thread(conversation).messages.first { $0.id == id }.map { message in
            (id: id, at: Int((message.sentAt.timeIntervalSince1970 * 1000).rounded()))
        }
    }

    func retry(_ id: String, in conversation: RoomConversation) async {
        guard outgoing[id] != nil || drafts[id] != nil else {
            return
        }
        update(conversation) { $0.retrying(id: id) }
        _ = await deliver(id, in: conversation, waitsForLink: false)
    }

    /// What became of one try to send a message.
    private enum Delivery {
        case kept
        /// No link, so it waits for one.
        case waiting
        case failed
    }

    private func deliver(_ id: String, in conversation: RoomConversation, waitsForLink: Bool) async -> Delivery {
        do {
            let message = try await prepared(id, in: conversation)
            let entry = try await connection.roomSend(message)
            outgoing[id] = nil
            update(conversation) { $0.apply(entry) }
            onSent?(conversation)
            return .kept
        } catch GatewayConnectionError.notConnected where waitsForLink {
            // With no link there is no reason to give up on it: it goes once the link is back,
            // and the gateway keeps the first of a message sent twice.
            update(conversation) { $0.wait(id: id) }
            return .waiting
        } catch {
            update(conversation) { $0.fail(id: id, reason: ErrorText.describe(error)) }
            return .failed
        }
    }

    /// Sends what waited for the link, one at a time in the order it was said, and stops at
    /// the first the link drops under again, which waits at the front for the next time. One
    /// the gateway turns out to have kept already, its answer lost with the link, is done.
    private func sendWaiting() async {
        guard !isSendingWaiting else {
            return
        }
        isSendingWaiting = true
        defer {
            isSendingWaiting = false
        }
        while let next = waitingForLink.first {
            waitingForLink.removeFirst()
            if thread(next.conversation).messages.contains(where: { $0.id == next.id && $0.rev != nil }) {
                outgoing[next.id] = nil
                drafts[next.id] = nil
            } else {
                update(next.conversation) { $0.retrying(id: next.id) }
                if await deliver(next.id, in: next.conversation, waitsForLink: true) == .waiting {
                    waitingForLink.insert(next, at: 0)
                    return
                }
            }
            waitingKept[next.id] = nil
            writeWaiting()
        }
    }

    /// The message as it will be sent: uploaded and signed once, then kept for retries.
    private func prepared(_ id: String, in conversation: RoomConversation) async throws -> RoomOutgoing {
        if let ready = outgoing[id] {
            return ready
        }
        guard let draft = drafts[id] else {
            throw GatewayConnectionError.unexpectedFrame
        }
        var media: [RoomMedia] = []
        for attachment in draft.attachments {
            media.append(try await upload(attachment))
        }
        let message = try RoomOutgoing(
            conversation: conversation,
            id: id,
            at: draft.at,
            replyTo: draft.replyTo,
            media: media,
            location: draft.location,
            text: draft.text,
            isCall: draft.isCall,
            sign: sign
        )
        outgoing[id] = message
        drafts[id] = nil
        return message
    }

    /// Sets this phone's person's face, their assistant's or the family room's own photo
    /// (`familyFaceId`, which either person may set) from a square JPEG, `side` pixels
    /// across. Everyone in the family room sees it, on both gateways. The family photo
    /// shows at once, and the next page confirms it.
    func setFace(of participant: String, jpeg: Data, side: Int) async throws {
        let photo = try await upload(RoomAttachment(data: jpeg, kind: .photo, mime: "image/jpeg", width: side, height: side))
        participants = try await connection.roomSetAvatar(participant: participant, media: photo)
        if participant == Self.familyFaceId {
            familyAvatar = photo
        }
        onParticipantsChanged?()
    }

    /// What the gateway calls the family room when its photo is set.
    static let familyFaceId = "family"

    /// The colour of the ring round the family room's face, nil for its own white edge.
    /// Both phones show it, and the room's line for it comes with the next catch-up.
    func setFamilyColor(_ ring: RingColor?) async throws {
        familyLook = try await connection.roomSetLookColor(ring)
    }

    /// The family room's appearance, and with Custom its background for everyone, nil to
    /// keep the latest one, the same way as the colour.
    func setFamilyAppearance(_ appearance: FamilyLook.Appearance, background: ChatBackground?) async throws {
        familyLook = try await connection.roomSetLookAppearance(appearance, background: background)
    }

    private func upload(_ attachment: RoomAttachment) async throws -> RoomMedia {
        let uploadId = makeId()
        let total = attachment.data.count
        var offset = 0
        while true {
            let end = min(offset + GatewayConnection.roomChunkBytes, total)
            let chunk = attachment.data.subdata(in: offset..<end)
            let receipt = try await connection.roomUpload(uploadId: uploadId, offset: offset, total: total, data: chunk)
            if receipt.complete, let id = receipt.id {
                return attachment.media(id: id)
            }
            guard receipt.received > offset else {
                throw GatewayConnectionError.unexpectedFrame
            }
            offset = receipt.received
        }
    }

    /// Sends to this phone's own thread and waits for the assistant's next reply there:
    /// what Siri asks through, so its exchanges are in the thread too.
    func ask(_ text: String, timeout: TimeInterval = RoomModel.replySeconds) async throws -> String {
        guard let person = me?.person else {
            throw GatewayConnectionError.notConnected
        }
        await send(text, in: .direct)
        guard let sent = direct.messages.last(where: { $0.author == person }) else {
            throw GatewayConnectionError.notConnected
        }
        if case .failed(let reason) = sent.status {
            throw GatewayErrorShape(code: Self.sendFailureCode, message: reason, details: nil)
        }
        guard let sentRev = sent.rev else {
            throw GatewayConnectionError.notConnected
        }
        if let reply = direct.messages.first(where: { $0.author == me?.assistant && ($0.rev ?? 0) > sentRev }) {
            return reply.text
        }
        let waiter = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            replyWaiters[waiter] = (sentRev, continuation)
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                self.replyWaiters.removeValue(forKey: waiter)?.continuation.resume(throwing: GatewayConnectionError.timedOut)
            }
        }
    }

    /// A new reply from this phone's assistant in its own thread, for whoever waits on one.
    private func answered(_ entry: RoomEntry) {
        let text = entry.text ?? ""
        for (waiter, waiting) in replyWaiters where waiting.afterRev < entry.rev {
            replyWaiters[waiter] = nil
            waiting.continuation.resume(returning: text)
        }
    }

    /// Shown at once; the gateway's own entry follows as a change. Answers whether the
    /// gateway took it.
    @discardableResult
    func react(to messageId: String, with emoji: String?, in conversation: RoomConversation) async -> Bool {
        guard let author = me?.person else {
            return false
        }
        update(conversation) { $0.react(messageId: messageId, author: author, emoji: emoji) }
        do {
            try await connection.roomReact(messageId: messageId, emoji: emoji)
            return true
        } catch {
            note(error)
            return false
        }
    }

    /// Shown at once, and kept by the gateway for the assistant's next turn. A tick the
    /// gateway refuses is taken back, so the list never shows what the assistant was not told.
    func tick(_ tick: ChecklistTick, isDone: Bool, in conversation: RoomConversation) async {
        let before = ticks[tick]
        ticks[tick] = isDone
        do {
            try await connection.roomTick(tick, isDone: isDone, in: conversation)
        } catch {
            ticks[tick] = before
            note(error)
        }
    }

    /// Ordered on a cart card, from whoever checked out. The cart as it now stands, and the
    /// order in this phone's own thread, arrive as messages like any other. Answers how
    /// many items the gateway marked, and throws its refusal.
    func markOrdered(cartIn messageId: String, in conversation: RoomConversation) async throws -> Int {
        try await connection.roomCartOrdered(messageId: messageId, in: conversation)
    }

    /// How an approval card in this phone's own thread ended, or this phone's answer to it
    /// while the gateway has not said. Nil while it waits.
    func approvalOutcome(of messageId: String) -> RoomApproval.Outcome? {
        direct.approvalOutcomes[messageId] ?? answers[messageId]
    }

    /// Signs this phone's answer to an approval card and sends it. The card shows the
    /// answer at once; one the gateway refuses is taken back, with why. A card that has
    /// ended, or a message that is no card, is never answered.
    func answer(_ message: RoomMessage, with decision: RoomApproval.Decision) async {
        guard let approval = message.approval, approvalOutcome(of: message.id) == nil else {
            return
        }
        approvalRefusals[message.id] = nil
        answers[message.id] = decision.outcome
        do {
            guard let text = ApprovalAnswer.signedText(approvalId: approval.id, decision: decision) else {
                throw GatewayErrorShape(code: "INVALID_REQUEST", message: "This answer cannot be signed.", details: nil)
            }
            try await connection.roomAnswerApproval(messageId: message.id, decision: decision, signature: try sign(text))
        } catch {
            answers[message.id] = nil
            approvalRefusals[message.id] = ErrorText.describe(error)
        }
    }

    /// This person's yes or no to a reminder by place in the family room that would watch
    /// them, signed by this phone. Shown at once; one the gateway refuses is taken back,
    /// with why. Answers whether the gateway took it.
    @discardableResult
    func answerPlace(_ messageId: String, with answer: PlaceAnswer) async -> Bool {
        guard let person = me?.person else {
            return false
        }
        let before = family.placeAnswers[messageId]?[person]
        placeRefusals[messageId] = nil
        update(.family) { $0.answer(messageId, by: person, with: answer) }
        let at = Int((now().timeIntervalSince1970 * 1000).rounded())
        do {
            guard let text = PlaceAnswer.signedText(messageId: messageId, answer: answer, at: at) else {
                throw GatewayErrorShape(code: "INVALID_REQUEST", message: "This answer cannot be signed.", details: nil)
            }
            try await connection.roomAnswerPlace(messageId: messageId, answer: answer, at: at, signature: try sign(text))
            return true
        } catch {
            update(.family) { $0.answer(messageId, by: person, with: before) }
            placeRefusals[messageId] = ErrorText.describe(error)
            return false
        }
    }

    /// A call with the assistant that ended: the gateway folds the messages its words were
    /// said in into one call entry with the words alone, and this thread shows that one
    /// row in their place. Signed by this phone, since it takes those messages away. One
    /// the gateway cannot take leaves the messages as they are. Answers whether it took it.
    /// `setup`, how the call came up, goes beside it for the gateway's log.
    @discardableResult
    func logCall(id callId: String, startedAt: Date, endedAt: Date, turns: [String], setup: CallSetup) async -> Bool {
        let started = Int((startedAt.timeIntervalSince1970 * 1000).rounded())
        let ended = Int((endedAt.timeIntervalSince1970 * 1000).rounded())
        do {
            guard let text = RoomSignature.callEndText(callId: callId, startedAt: started, endedAt: ended, turns: turns) else {
                return false
            }
            let entry = try await connection.roomCallEnd(
                callId: callId,
                startedAt: started,
                endedAt: ended,
                turns: turns,
                signature: try sign(text),
                setup: setup
            )
            update(.direct) { $0.apply(entry) }
            return true
        } catch {
            return false
        }
    }

    /// Tells the gateway this phone has read up to the newest message somebody else wrote.
    func markRead(_ conversation: RoomConversation) async {
        guard
            let latest = thread(conversation).messages.last(where: { $0.rev != nil && $0.author != me?.person }),
            lastRead[conversation] != latest.id
        else {
            return
        }
        lastRead[conversation] = latest.id
        do {
            try await connection.roomRead(conversation, messageId: latest.id)
        } catch {
            lastRead[conversation] = nil
        }
    }

    /// Tells the family room this person is typing while their draft has words: again every
    /// `typingRefreshSeconds` while they go on, since the gateway forgets a typing after
    /// `typingSeconds`, and once that they stopped when the draft is emptied or sent. Their
    /// own thread has nobody else to tell.
    func noteDraft(_ text: String, in conversation: RoomConversation) async {
        guard conversation == .family else {
            return
        }
        let isTyping = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let moment = now()
        if isTyping {
            if let said = saidTypingAt[conversation], moment.timeIntervalSince(said) < Self.typingRefreshSeconds {
                return
            }
            saidTypingAt[conversation] = moment
        } else if saidTypingAt.removeValue(forKey: conversation) == nil {
            return
        }
        try? await connection.roomTyping(conversation, isActive: isTyping)
    }

    // MARK: - Events

    func handle(_ event: GatewayEvent) {
        if let roomEvent = RoomEvent(event) {
            switch roomEvent {
            case .changed(let changedRev):
                if changedRev > rev {
                    Task {
                        await self.catchUp()
                    }
                }
            case .typing(let conversation, let author, let isActive):
                typingUntil[conversation, default: [:]][author] = isActive ? now().addingTimeInterval(Self.typingSeconds) : nil
                summarize(conversation)
                if isActive {
                    // A typing that is never stopped ends on its own, and the screen
                    // has to hear that too.
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(Self.typingSeconds))
                        self?.forgetStaleTyping()
                    }
                }
            }
            return
        }
        if let tool = AgentToolEvent(event) {
            follow(tool)
            return
        }
        if event.event == PairPage.eventName {
            if let lastAt = event.payload?["lastAt"]?.intValue {
                pairMoved(at: lastAt)
            }
            return
        }
        guard
            case .chat(let chat) = event.body,
            let conversation = followedConversation(chat.sessionKey),
            let assistant = me?.assistant
        else {
            return
        }
        switch chat.state {
        case .delta:
            stream(StreamedWords(runId: chat.runId, author: assistant, text: chat.deltaText ?? "", replace: chat.replace == true), in: conversation)
        case .final:
            update(conversation) {
                $0.endStream(runId: chat.runId, failure: nil)
            }
            ready(runId: chat.runId, in: conversation)
            forgetActivity(in: conversation)
            endSteps(in: conversation)
            forgetTyping(of: assistant, in: conversation)
        case .aborted, .error:
            update(conversation) {
                $0.endStream(runId: chat.runId, failure: chat.errorMessage ?? Self.unfinishedReplyReason)
            }
            ready(runId: chat.runId, in: conversation)
            forgetActivity(in: conversation)
            endSteps(in: conversation)
            forgetTyping(of: assistant, in: conversation)
        case .status, .unknown:
            break
        }
    }

    /// Which conversation a session's replies and tool steps are in: each conversation's own,
    /// and the family room for the person's own session of it.
    private func followedConversation(_ key: String) -> RoomConversation? {
        key == ownersFamilySession ? .family : sessionKeys.first(where: { $0.value == key })?.key
    }

    /// A tool starting says what the assistant is busy with, in the typing bubble, until
    /// that same call's result. A step never stays in the thread as a line: the owner
    /// wants only the reply there.
    private func follow(_ tool: AgentToolEvent) {
        guard let conversation = followedConversation(tool.sessionKey) else {
            return
        }
        switch tool.phase {
        case .start:
            let activity = AssistantActivity(tool: tool.name, command: tool.command)
            activities[conversation] = activity
            toolCalls[conversation] = tool.toolCallId
            step(activity, in: conversation)
        case .result:
            if toolCalls[conversation] == tool.toolCallId {
                forgetActivity(in: conversation)
                step(nil, in: conversation)
            }
        case .update, .unknown:
            break
        }
    }

    private func forgetActivity(in conversation: RoomConversation) {
        activities[conversation] = nil
        toolCalls[conversation] = nil
    }

    /// Puts what the assistant is doing now on the working line once the step there has
    /// been held long enough to read (ToolSteps). Every event comes through here, so a tool
    /// that starts and finishes between two frames still holds the line.
    private func step(_ activity: AssistantActivity?, in conversation: RoomConversation) {
        steps[conversation, default: ToolSteps()].follow(activity, at: now())
        waitForNextStep(in: conversation)
    }

    private func waitForNextStep(in conversation: RoomConversation) {
        stepping[conversation]?.cancel()
        stepping[conversation] = nil
        guard let next = steps[conversation]?.nextChange else {
            return
        }
        let wait = max(0, next.timeIntervalSince(now()))
        stepping[conversation] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else {
                return
            }
            self.steps[conversation]?.advance(at: self.now())
            self.waitForNextStep(in: conversation)
        }
    }

    /// The run is over, so its assistant is no longer typing, though the gateway says so
    /// until it has kept the reply: the dots never come back under the reply just finished.
    private func forgetTyping(of author: String, in conversation: RoomConversation) {
        guard typingUntil[conversation]?[author] != nil else {
            return
        }
        typingUntil[conversation]?[author] = nil
        summarize(conversation)
    }

    /// The run is over: its reply takes the typing bubble's place, and no step waits.
    private func endSteps(in conversation: RoomConversation) {
        stepping[conversation]?.cancel()
        stepping[conversation] = nil
        steps[conversation] = nil
    }

    /// Makes a reply that has just finished streaming ready to draw before the thread shows
    /// it, so it lands whole at its full height rather than empty for as long as a parse
    /// takes.
    private func ready(runId: String, in conversation: RoomConversation) {
        let id = RoomThread.streamPrefix + runId
        guard let prepare, let reply = thread(conversation).messages.first(where: { $0.id == id }) else {
            return
        }
        readying[conversation, default: []].insert(id)
        Task { [weak self] in
            await prepare([reply])
            self?.readying[conversation]?.remove(id)
        }
    }

    /// A different assistant's conversations must never carry over.
    func reset() {
        // A write already under way is past being cancelled, and would put a conversation
        // back after it was forgotten, so the archive is forgotten again once it ends.
        let underWay = [keeping, waitingWrite]
        keeping?.cancel()
        keeping = nil
        kept = [:]
        hasReadPage = false
        archive?.forget()
        if let archive {
            forgetting = Task.detached(priority: .utility) {
                for write in underWay {
                    await write?.value
                }
                archive.forget()
            }
            waitingWrite = forgetting
        }
        flushingWords?.cancel()
        flushingWords = nil
        waitingWords = [:]
        family = RoomThread(.family)
        direct = RoomThread(.direct)
        keptFamily = RoomThread(.family)
        keptDirect = RoomThread(.direct)
        familySummary = .empty
        directSummary = .empty
        participants = []
        me = nil
        peerAssistant = nil
        familyAvatar = nil
        familyLook = nil
        pairLastAt = nil
        rev = 0
        isAvailable = nil
        errorText = nil
        ticks = [:]
        answers = [:]
        approvalRefusals = [:]
        placeRefusals = [:]
        messageCards = [:]
        sessionKeys = [:]
        ownersFamilySession = nil
        outgoing = [:]
        drafts = [:]
        waitingForLink = []
        waitingKept = [:]
        typingUntil = [:]
        activities = [:]
        toolCalls = [:]
        for wait in stepping.values {
            wait.cancel()
        }
        stepping = [:]
        steps = [:]
        readying = [:]
        lastRead = [:]
        let waiting = replyWaiters
        replyWaiters = [:]
        for (_, waiter) in waiting {
            waiter.continuation.resume(throwing: GatewayConnectionError.notConnected)
        }
    }

    // MARK: - Private

    /// A message whose attachments never finished uploading.
    private struct Draft {
        let text: String
        let replyTo: String?
        let attachments: [RoomAttachment]
        let location: SharedLocation?
        let at: Int
        let isCall: Bool
    }

    private func forgetStaleTyping() {
        let moment = now()
        for (conversation, authors) in typingUntil {
            typingUntil[conversation] = authors.filter { $0.value > moment }
            summarize(conversation)
        }
    }

    /// Changes one conversation, after any words still waiting to stream into it, and
    /// tells the screen only when the conversation really changed: a catch-up or a
    /// reconnect that brings nothing new never redraws the thread.
    private func update(_ conversation: RoomConversation, _ change: (inout RoomThread) -> Void) {
        let before = thread(conversation)
        var after = before
        for words in waitingWords.removeValue(forKey: conversation) ?? [] {
            after.stream(runId: words.runId, author: words.author, text: words.text, replace: words.replace)
        }
        change(&after)
        after.boundHistory()
        guard after != before else {
            return
        }
        switch conversation {
        case .family:
            family = after
        case .direct:
            direct = after
        }
        summarize(conversation)
    }

    /// Brings what Chats and the widgets read of a conversation in step with its thread
    /// and with who is typing there. Each is replaced only when it differs, so whatever
    /// reads it is told only of a change it shows.
    private func summarize(_ conversation: RoomConversation) {
        let kept = thread(conversation).kept
        let summary = ConversationSummary(kept, readBy: me?.person, isTyping: !typing(in: conversation).isEmpty)
        switch conversation {
        case .family:
            if kept != keptFamily {
                keptFamily = kept
            }
            if summary != familySummary {
                familySummary = summary
            }
        case .direct:
            if kept != keptDirect {
                keptDirect = kept
            }
            if summary != directSummary {
                directSummary = summary
            }
        }
    }

    /// Words of a streaming reply, kept for `streamInterval` from the first of them so that
    /// every piece arriving meanwhile reaches the thread in the same one change. Anything
    /// else that changes the thread, the reply's end among them, takes the words waiting
    /// for it first, so none is ever lost or shown out of order.
    private func stream(_ words: StreamedWords, in conversation: RoomConversation) {
        waitingWords[conversation, default: []].append(words)
        guard flushingWords == nil else {
            return
        }
        flushingWords = Task { [weak self] in
            try? await Task.sleep(for: Self.streamInterval)
            // A reset cancels the wait and drops the words, and a later reply may have
            // started a wait of its own in its place.
            guard !Task.isCancelled, let self else {
                return
            }
            self.flushingWords = nil
            for waiting in self.waitingWords.keys {
                self.update(waiting) { _ in }
            }
        }
    }

    /// Keeps a conversation's newest page, and writes the archive a moment later.
    private func keep(_ page: RoomArchive.Kept, for conversation: RoomConversation) {
        guard archive != nil else {
            return
        }
        kept[conversation] = page.bounded()
        writeArchiveSoon()
    }

    /// Adds a sync page's changes to the conversations they belong to, after each one's page.
    private func keep(changes entries: [JSONValue]) {
        guard archive != nil, !entries.isEmpty else {
            return
        }
        for conversation in RoomConversation.allCases {
            let theirs = entries.filter { $0["conversation"]?.stringValue == conversation.rawValue }
            if !theirs.isEmpty, let kept = kept[conversation] {
                self.kept[conversation] = kept.adding(theirs)
            }
        }
        writeArchiveSoon()
    }

    /// Writes what is kept away from the main actor, once a burst of changes has settled.
    private func writeArchiveSoon() {
        guard let archive else {
            return
        }
        keeping?.cancel()
        let snapshot = kept
        let forgetting = forgetting
        keeping = Task.detached(priority: .utility) {
            await forgetting?.value
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else {
                return
            }
            for (conversation, kept) in snapshot {
                archive.write(kept, for: conversation)
            }
        }
    }

    private func orient(
        participants: [RoomParticipant],
        me: RoomSelf,
        sessionKeys: [RoomConversation: String],
        ownersFamilySession: String?,
        familyAvatar: RoomMedia?,
        familyLook: FamilyLook?,
        pair: RoomPair?
    ) {
        let hasChanged = participants != self.participants || me != self.me
        if let pair {
            pairMoved(at: pair.lastAt)
        }
        if familyAvatar != self.familyAvatar {
            self.familyAvatar = familyAvatar
        }
        if familyLook != self.familyLook {
            self.familyLook = familyLook
        }
        if participants != self.participants {
            self.participants = participants
        }
        if me != self.me {
            self.me = me
            // Unread counts are this phone's person's.
            for conversation in RoomConversation.allCases {
                summarize(conversation)
            }
        }
        self.sessionKeys = sessionKeys
        self.ownersFamilySession = ownersFamilySession
        if hasChanged {
            onParticipantsChanged?()
        }
    }

    /// Only ever later: a page read before the line's latest event must not take it back.
    private func pairMoved(at lastAt: Int) {
        if lastAt > (pairLastAt ?? 0) {
            pairLastAt = lastAt
        }
    }

    private func note(_ error: Error) {
        if let shape = error as? GatewayErrorShape, shape.message.contains("unknown method") {
            isAvailable = false
            return
        }
        errorText = ErrorText.describe(error)
    }
}
