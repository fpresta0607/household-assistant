// The assistant's day at a glance for the top of Chats (CFO notes section 21c). It is kept
// on the phone beside the conversations (RoomArchive) and shown from there at once, offline
// too, then read again from this phone's own gateway when the link comes up, and the
// plugin's `today` event replaces it whenever the assistant writes a new one. What it shows
// moves on by the phone's own clock (TodayGlance), so a morning shows the morning and an
// evening shows tonight and tomorrow.
//
// The whole card shows the first time each day. Once its person has seen it, as they leave
// Chats with it on screen, or has checked it off, it folds to a slim banner for the rest of
// that day, which opens the whole card again on a tap, and the next day it shows whole.

import Foundation
import Observation

@MainActor
@Observable
final class TodayModel {
    /// What the card shows now, or nil when there is nothing to show.
    private(set) var glance: TodayGlance?
    /// Everything on the card, for the whole day a tap opens.
    private(set) var lines: [TodayGlance.Line] = []
    /// When the whole card was last seen or checked off.
    private(set) var seenAt: Date?
    private(set) var seenVerseDay: String?
    private var displayedAt: Date
    /// Whether the banner was opened back into the whole card, until Chats is left.
    private(set) var isOpened = false

    @ObservationIgnored private var card: TodayCard?
    @ObservationIgnored private let connection: GatewayConnection
    @ObservationIgnored private let archive: RoomArchive?
    @ObservationIgnored private let seen: TodaySeenStore?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar
    /// Moves the card on when what it shows next changes.
    @ObservationIgnored private var moving: Task<Void, Never>?

    init(
        connection: GatewayConnection,
        archive: RoomArchive?,
        seen: TodaySeenStore? = nil,
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.connection = connection
        self.archive = archive
        self.seen = seen
        self.now = now
        self.calendar = calendar
        displayedAt = now()
        seenAt = seen?.todaySeenAt
        seenVerseDay = seen?.todaySeenVerseDay
        if let kept = archive?.readToday(), let card = try? kept.decoded(as: TodayCard.self) {
            show(card)
        }
    }

    /// Whether the card shows as a slim banner: its person saw the whole of it earlier
    /// today, and has not opened it again since.
    var isFolded: Bool {
        guard let seenAt else {
            return false
        }
        // An overnight visit must not consume the next morning. A verse arriving after
        // a calendar-only card was seen also deserves its first expanded showing.
        let hasUnreadVerse = glance?.verse != nil && card?.day != seenVerseDay
        return TodayGlance.morning(containing: seenAt, calendar: calendar)
            == TodayGlance.morning(containing: displayedAt, calendar: calendar)
            && !hasUnreadVerse && !isOpened
    }

    /// Its person has seen the whole card, leaving Chats with it on screen, or checked it
    /// off: it is a banner for the rest of the day.
    func markSeen() {
        guard glance != nil, !isFolded else { return }
        let moment = now()
        seenAt = moment
        seen?.todaySeenAt = moment
        if glance?.verse != nil {
            seenVerseDay = card?.day
            seen?.todaySeenVerseDay = seenVerseDay
        }
        isOpened = false
    }

    /// Re-evaluate a cached card when iOS resumes the app after its clock was suspended.
    func updateClock() {
        show(card)
    }

    /// The banner was tapped: the whole card again, until Chats is left.
    func open() {
        isOpened = true
    }

    /// When the gateway cannot be asked, the card kept on the phone stays.
    func refresh() async {
        let answer: JSONValue
        do {
            answer = try await connection.today()
        } catch {
            return
        }
        take(answer)
    }

    func handle(_ event: GatewayEvent) {
        guard event.event == TodayCard.eventName, let today = event.payload?["today"] else {
            return
        }
        take(today)
    }

    /// Pairing with another gateway, or again: another assistant's day never carries over.
    func reset() {
        archive?.writeToday(nil)
        seen?.todaySeenAt = nil
        seen?.todaySeenVerseDay = nil
        seenAt = nil
        seenVerseDay = nil
        isOpened = false
        show(nil)
    }

    /// Keeps what the gateway sent as it came, unless it is not a card at all, which leaves
    /// the one showing.
    private func take(_ today: JSONValue) {
        guard today != .null else {
            archive?.writeToday(nil)
            show(nil)
            return
        }
        guard let card = try? today.decoded(as: TodayCard.self) else {
            return
        }
        archive?.writeToday(today)
        show(card)
    }

    private func show(_ card: TodayCard?) {
        moving?.cancel()
        self.card = card
        let moment = now()
        displayedAt = moment
        guard let card else {
            glance = nil
            lines = []
            return
        }
        glance = TodayGlance(card: card, at: moment, calendar: calendar)
        lines = TodayGlance.lines(of: card, at: moment, calendar: calendar)
        guard let change = TodayGlance.nextChange(of: card, after: moment, calendar: calendar) else {
            return
        }
        let secondsLeft = change.timeIntervalSince(moment)
        moving = Task { [weak self] in
            try? await Task.sleep(for: .seconds(secondsLeft))
            guard !Task.isCancelled else {
                return
            }
            self?.show(self?.card)
        }
    }
}
