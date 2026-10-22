// One household-app conversation as the screen shows it, built from the gateway's
// entries. A value type with no I/O, so every rule is covered by a plain test.
//
// The gateway's revisions order what it has kept. What it has not kept yet, this
// phone's own sends and an assistant's reply still streaming in, goes after all of it
// in the order it began, and takes its place in the revision order once the entry for
// it arrives. An entry that arrives twice changes nothing.
//
// While this phone's assistant works, each kind of thing it does is a line under the
// message its run answers, so the lines stay there when the reply arrives below them.
//
// A live map moves with the newest move the gateway kept, never an older one, and a
// reminder by place shows who said yes or no to it.
//
// Each change to the family room's look is a line among the messages, at its time.

import Foundation

struct RoomThread: Equatable, Sendable {
    let conversation: RoomConversation
    private(set) var messages: [RoomMessage] = []
    /// How far each participant has read: author to message id.
    private(set) var reads: [String: String] = [:]
    /// Whether the gateway holds messages older than the oldest here.
    private(set) var hasOlder = false
    /// How each approval card here ended, by message id. A card not here still waits.
    private(set) var approvalOutcomes: [String: RoomApproval.Outcome] = [:]
    /// Each person's answer to a reminder by place here, by message id then person.
    private(set) var placeAnswers: [String: [String: PlaceAnswer]] = [:]
    /// The changes to the family room's look made here, oldest first.
    private(set) var lookLines: [FamilyLookLine] = []

    init(_ conversation: RoomConversation) {
        self.conversation = conversation
    }

    static let streamPrefix = "run:"

    /// A window of saved history, not a retention policy for the server. Pending sends
    /// are never evicted. One exceptionally large message remains readable in full.
    static let mostLoadedMessages = 1_000
    static let mostLoadedTextBytes = 4 * 1_024 * 1_024

    @discardableResult
    mutating func boundHistory(keepingNewest: Bool = true) -> Bool {
        let kept = messages.filter { $0.rev != nil }
        var count = 0
        var bytes = 0
        var ids = Set<String>()
        let ordered = keepingNewest ? Array(kept.reversed()) : kept
        for message in ordered {
            let size = message.text.utf8.count + (message.heard?.utf8.count ?? 0)
                + (message.call?.transcript.reduce(0) { $0 + $1.text.utf8.count } ?? 0)
            if count > 0 && (count >= Self.mostLoadedMessages || bytes + size > Self.mostLoadedTextBytes) { break }
            ids.insert(message.id)
            count += 1
            bytes += size
        }
        let dropped = ids.count < kept.count
        guard dropped else { return false }
        messages.removeAll { $0.rev != nil && !ids.contains($0.id) }
        approvalOutcomes = approvalOutcomes.filter { ids.contains($0.key) }
        placeAnswers = placeAnswers.filter { ids.contains($0.key) }
        if let oldestRev, let latestRev {
            lookLines.removeAll { $0.rev < oldestRev || $0.rev > latestRev }
        }
        if keepingNewest { hasOlder = true }
        return true
    }

    var latestRev: Int? {
        messages.compactMap(\.rev).max()
    }

    var oldestRev: Int? {
        messages.compactMap(\.rev).min()
    }

    var lastMessageId: String? {
        messages.last { $0.rev != nil }?.id
    }

    /// What the gateway has kept here: this thread without what is still on its way, a
    /// send or a streaming reply. All that Chats' shared strip and the widgets show of a
    /// conversation.
    var kept: RoomThread {
        var kept = self
        kept.messages.removeAll { $0.rev == nil }
        return kept
    }

    /// Every photo and video the gateway has kept here, oldest first, with the message
    /// that carried it: what the full-screen viewer swipes through.
    var photosAndVideos: [(message: RoomMessage, media: RoomMedia)] {
        messages.filter { $0.rev != nil }.flatMap { message in
            message.media.filter(\.kind.isVisual).map { (message: message, media: $0) }
        }
    }

    /// The first message `author` wrote after `messageId`: an assistant's answer to it,
    /// while it streams in and once it is kept.
    func reply(to messageId: String, from author: String) -> RoomMessage? {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else {
            return nil
        }
        return messages[(index + 1)...].first { $0.author == author }
    }

    /// The newest page, read on opening and after a reconnect. A message already on screen
    /// keeps its bubble.
    mutating func load(_ page: RoomHistoryPage) {
        let unkept = messages.filter { $0.rev == nil }
        let newer = messages.filter { message in
            guard let rev = message.rev, let newest = page.messages.last?.rev else {
                return false
            }
            return rev > newest
        }
        let bubbles = Dictionary(messages.map { ($0.id, $0.bubbleId) }, uniquingKeysWith: { first, _ in first })
        messages = page.messages.map { entry in
            var shown = message(from: entry, on: page)
            shown.bubbleId = bubbles[entry.id] ?? entry.id
            return shown
        } + newer
        reads = Dictionary(page.reads.map { ($0.author, $0.messageId) }, uniquingKeysWith: { _, last in last })
        hasOlder = page.hasMore
        learnOutcomes(page)
        learnAnswers(page)
        // The newest page holds every change from its oldest message on, and older pages
        // read before it are gone, so are theirs.
        lookLines = []
        learnLooks(page.looks ?? [])
        for message in unkept where !messages.contains(where: { $0.id == message.id }) {
            messages.append(message)
        }
        dropFoldedIntoCalls()
    }

    /// A page from further back, put in front of what is here.
    mutating func loadOlder(_ page: RoomHistoryPage) {
        let known = Set(messages.map(\.id))
        let older = page.messages
            .filter { !known.contains($0.id) }
            .map { message(from: $0, on: page) }
        messages = older + messages
        sortKept()
        dropFoldedIntoCalls()
        hasOlder = page.hasMore
        learnOutcomes(page)
        learnAnswers(page)
        learnLooks(page.looks ?? [])
    }

    mutating func apply(_ entry: RoomEntry) {
        guard entry.roomConversation == conversation else {
            return
        }
        switch entry.kind {
        case .message:
            // The streamed copy of this reply gives way to the kept one: by its run when the
            // entry names one, otherwise every stream of the same assistant, because the
            // channel's own replies arrive without the run that made them. An approval card
            // is no reply: the run that asks goes on streaming once it is answered. The kept
            // copy stays in the streamed one's bubble.
            let isStreamOfThis: (RoomMessage) -> Bool
            if let runId = entry.runId {
                isStreamOfThis = { $0.id == Self.streamPrefix + runId }
            } else if entry.approval == nil {
                isStreamOfThis = { $0.id.hasPrefix(Self.streamPrefix) && $0.author == entry.author }
            } else {
                isStreamOfThis = { _ in false }
            }
            let streamedBubble = messages.first(where: isStreamOfThis)?.bubbleId
            messages.removeAll(where: isStreamOfThis)
            if let index = messages.firstIndex(where: { $0.id == entry.id }) {
                guard messages[index].rev == nil else {
                    return
                }
                let reactions = messages[index].reactions
                let heard = messages[index].heard
                messages[index] = RoomMessage(entry)
                messages[index].reactions = reactions
                messages[index].heard = heard
            } else {
                var kept = RoomMessage(entry)
                kept.bubbleId = streamedBubble ?? entry.id
                messages.append(kept)
            }
            sortKept()
            // One a call already folded, arriving after it, stays out.
            dropFoldedIntoCalls()
        case .reaction:
            guard let messageId = entry.messageId, let index = messages.firstIndex(where: { $0.id == messageId }) else {
                return
            }
            messages[index].reactions.removeAll { $0.author == entry.author }
            if let emoji = entry.emoji {
                messages[index].reactions.append(RoomReaction(author: entry.author, emoji: emoji))
            }
        case .read:
            if let messageId = entry.messageId {
                reads[entry.author] = messageId
            }
        case .approval:
            if let messageId = entry.messageId, let outcome = entry.approvalOutcome {
                approvalOutcomes[messageId] = outcome
            }
        case .live:
            if let messageId = entry.messageId, let index = messages.firstIndex(where: { $0.id == messageId }) {
                messages[index].move(RoomLive(at: entry.at, position: entry.position))
            }
        case .place:
            if let messageId = entry.messageId, let answer = entry.answer {
                placeAnswers[messageId, default: [:]][entry.author] = answer
            }
        case .transcript:
            if let messageId = entry.messageId, let index = messages.firstIndex(where: { $0.id == messageId }) {
                messages[index].heard = entry.words
            }
        case .call:
            guard RoomCall(entry) != nil, !messages.contains(where: { $0.id == entry.id }) else {
                return
            }
            messages.append(RoomMessage(entry))
            sortKept()
            dropFoldedIntoCalls()
        case .look:
            learnLooks([entry])
        case .unknown:
            break
        }
    }

    /// Lines for changes to the family room's look, each once, in the order they were made.
    private mutating func learnLooks(_ entries: [RoomEntry]) {
        let known = Set(lookLines.map(\.id))
        let added = entries.compactMap(\.lookLine).filter { !known.contains($0.id) }
        guard !added.isEmpty else {
            return
        }
        lookLines = (lookLines + added).sorted { ($0.sentAt, $0.rev) < ($1.sentAt, $1.rev) }
    }

    mutating func addPending(_ message: RoomMessage) {
        messages.append(message)
    }

    mutating func fail(id: String, reason: String) {
        if let index = messages.firstIndex(where: { $0.id == id && $0.rev == nil }) {
            messages[index].status = .failed(reason)
        }
    }

    /// A message this phone said that waits for the link to come back.
    mutating func wait(id: String) {
        if let index = messages.firstIndex(where: { $0.id == id && $0.rev == nil }) {
            messages[index].status = .waiting
        }
    }

    mutating func retrying(id: String) {
        if let index = messages.firstIndex(where: { $0.id == id && $0.rev == nil }) {
            messages[index].status = .sending
        }
    }

    /// One piece of an assistant's reply, from the gateway's `chat` events.
    mutating func stream(runId: String, author: String, text: String, replace: Bool) {
        let id = Self.streamPrefix + runId
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text = replace ? text : messages[index].text + text
        } else {
            messages.append(RoomMessage(
                id: id,
                author: author,
                text: text,
                media: [],
                replyTo: nil,
                sentAt: Date(),
                status: .streaming,
                runId: runId
            ))
        }
    }

    /// The run ended. A reply that finished is kept until its entry replaces it; one
    /// that broke off says so.
    mutating func endStream(runId: String, failure: String?) {
        guard let index = messages.firstIndex(where: { $0.id == Self.streamPrefix + runId }) else {
            return
        }
        messages[index].status = failure.map(RoomMessage.Status.failed) ?? .sent
    }

    /// This phone's own answer to a reminder by place, shown before the gateway's entry for
    /// it arrives, or taken back with nil.
    mutating func answer(_ messageId: String, by person: String, with answer: PlaceAnswer?) {
        placeAnswers[messageId, default: [:]][person] = answer
    }

    /// This phone's own reaction, shown before the gateway's entry for it arrives.
    mutating func react(messageId: String, author: String, emoji: String?) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else {
            return
        }
        messages[index].reactions.removeAll { $0.author == author }
        if let emoji {
            messages[index].reactions.append(RoomReaction(author: author, emoji: emoji))
        }
    }

    /// Whether a later message here from one of `assistants` carries the cart `cartId`, whose
    /// card then takes the place of the one in `messageId`, so the thread shows the cart as
    /// it is now. A cart still arriving counts once its block has closed.
    func isCartReplaced(_ cartId: String, in messageId: String, assistants: Set<String>) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else {
            return false
        }
        return messages[(index + 1)...].contains { message in
            guard assistants.contains(message.author), message.text.contains(StewardCardParser.fence) else {
                return false
            }
            return StewardCardParser.segments(in: message.text, isStreaming: message.status == .streaming).contains { segment in
                if case .card(let card) = segment, case .cart(let cart) = card.content {
                    return cart.id == cartId
                }
                return false
            }
        }
    }

    /// What others wrote after this person's read marker: the badge on a conversation.
    func unreadCount(for person: String) -> Int {
        let readRev = reads[person].flatMap { readId in messages.first { $0.id == readId }?.rev } ?? 0
        return messages.filter { ($0.rev ?? 0) > readRev && $0.author != person }.count
    }

    /// Who has read this message: everyone whose read marker is at it or after it.
    func readers(of messageId: String) -> [String] {
        guard let rev = messages.first(where: { $0.id == messageId })?.rev else {
            return []
        }
        return reads
            .filter { _, readId in (messages.first { $0.id == readId }?.rev ?? -1) >= rev }
            .map(\.key)
            .sorted()
    }

    /// A page says how its own cards ended; what this thread knew of others stays.
    private mutating func learnOutcomes(_ page: RoomHistoryPage) {
        for (messageId, state) in page.approvals ?? [:] {
            if let outcome = RoomApproval.Outcome(rawValue: state) {
                approvalOutcomes[messageId] = outcome
            }
        }
    }

    /// Who answered each reminder by place on a page; what this thread knew of others stays.
    private mutating func learnAnswers(_ page: RoomHistoryPage) {
        for (messageId, answers) in page.places ?? [:] {
            for answer in answers {
                if let said = PlaceAnswer(rawValue: answer.answer) {
                    placeAnswers[messageId, default: [:]][answer.author] = said
                }
            }
        }
    }

    private func message(from entry: RoomEntry, on page: RoomHistoryPage) -> RoomMessage {
        var message = RoomMessage(entry)
        message.reactions = page.reactions[entry.id] ?? []
        message.heard = page.transcripts?[entry.id]
        if let moved = page.lives?[entry.id] {
            message.move(moved)
        }
        return message
    }

    /// A call that ended stands for the messages its words were said in, so they go.
    private mutating func dropFoldedIntoCalls() {
        let folded = Set(messages.compactMap(\.call).flatMap(\.turnIds))
        guard !folded.isEmpty else {
            return
        }
        messages.removeAll { folded.contains($0.id) }
    }

    /// Kept messages in revision order, then everything not kept yet in its own order.
    private mutating func sortKept() {
        let kept = messages.filter { $0.rev != nil }.sorted { ($0.rev ?? 0) < ($1.rev ?? 0) }
        let unkept = messages.filter { $0.rev == nil }
        messages = kept + unkept
    }
}
