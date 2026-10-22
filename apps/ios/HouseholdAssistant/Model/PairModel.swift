// The Corey & Denise group: every step the two assistants take on their direct line, which
// both parents watch, read from this phone's own gateway. The newest page is read when the
// link comes up and again whenever the plugin's `pair` event says the line moved, and older
// pages as the person scrolls up to them. Nothing is kept on the phone, since the gateway
// keeps the whole line, and nothing is sent: the group is read-only.

import Foundation
import Observation

@MainActor
@Observable
final class PairModel {
    /// The steps read so far, oldest first.
    private(set) var events: [PairEvent] = []
    /// The group's lines, a burst of rows as one (PairEntry).
    private(set) var entries: [PairEntry] = []
    /// Whether steps older than the first one here are left on the gateway.
    private(set) var hasOlder = false

    @ObservationIgnored private let connection: GatewayConnection
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var isReadingOlder = false

    init(connection: GatewayConnection) {
        self.connection = connection
    }

    func handle(_ event: GatewayEvent) {
        guard event.event == PairPage.eventName else {
            return
        }
        Task {
            await self.refresh()
        }
    }

    /// The newest page, joined to what is here. Calls that arrive while one is reading are
    /// folded into one more read after it, so an earlier page never lands over a later one.
    func refresh() async {
        if let running = refreshing {
            refreshAgain = true
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else {
                return
            }
            repeat {
                self.refreshAgain = false
                await self.readNewest()
            } while self.refreshAgain
            // In the same step as the last look at `refreshAgain`, as in RoomModel.catchUp.
            self.refreshing = nil
        }
        refreshing = task
        await task.value
    }

    /// The page before the oldest step here. When the gateway cannot be asked, the group
    /// stays as it is.
    func loadOlder() async {
        guard hasOlder, !isReadingOlder, let oldest = events.first else {
            return
        }
        isReadingOlder = true
        defer { isReadingOlder = false }
        // A newest page that left a gap may have replaced the steps this page would join.
        guard let page = try? await connection.pairPage(before: oldest.at), events.first?.id == oldest.id else {
            return
        }
        show(page.events + events, hasOlder: page.more)
    }

    /// Pairing with another gateway, or again: another household's line never carries over.
    func reset() {
        show([], hasOlder: false)
    }

    private func readNewest() async {
        guard let page = try? await connection.pairPage(before: nil) else {
            return
        }
        guard let first = page.events.first else {
            show([], hasOlder: false)
            return
        }
        // A full page that does not reach back to the newest step here leaves a gap between
        // them, so what is here gives way to it and is read again as the person scrolls up.
        let isJoined = !page.more || (events.last.map { $0.at >= first.at } ?? true)
        let older = isJoined ? events.filter { $0.at < first.at } : []
        show(older + page.events, hasOlder: older.isEmpty ? page.more : hasOlder)
    }

    private func show(_ shown: [PairEvent], hasOlder: Bool) {
        if shown != events {
            events = shown
            entries = PairEntry.entries(of: shown)
        }
        if hasOlder != self.hasOlder {
            self.hasOlder = hasOlder
        }
    }
}
