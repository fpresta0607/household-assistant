// The reminders by place this phone watches, and what goes off when.
//
// Each is set from a card, by its person's tap or yes, and watched by iOS on this phone
// (the app's place watcher), which says which side of a place's edge the person is on
// whenever it learns. A reminder goes off once, on the crossing its card names, and is
// then no longer watched. None of it goes to the gateway: the places stay on the phone.

import Foundation
import Observation

@MainActor
@Observable
final class PlaceReminders {
    @ObservationIgnored private let store: PlaceWatchStore
    /// Mirrors the store, so the cards follow what is watched.
    private(set) var watches: [PlaceWatch]
    /// The reminders that went off, by message id.
    private(set) var goneOff: Set<String>
    /// Told whenever what is watched changes, so iOS watches exactly these places.
    @ObservationIgnored var onChange: (() -> Void)?

    init(store: PlaceWatchStore) {
        self.store = store
        watches = store.placeWatches
        goneOff = Set(store.firedPlaceWatches)
    }

    func isWatching(_ id: String) -> Bool {
        watches.contains { $0.id == id }
    }

    func hasFired(_ id: String) -> Bool {
        goneOff.contains(id)
    }

    /// Watches a place from now on. The same card twice is one reminder.
    func watch(_ watch: PlaceWatch) {
        guard !isWatching(watch.id) else {
            return
        }
        save(watches + [watch])
    }

    func unwatch(_ id: String) {
        guard isWatching(id) else {
            return
        }
        save(watches.filter { $0.id != id })
    }

    /// iOS saw the person on one side of a watched place's edge. Answers the reminder when
    /// this is the crossing it waits for, and from then on watches it no more.
    func saw(_ id: String, isInside: Bool) -> PlaceWatch? {
        guard let index = watches.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let side: PlaceWatch.Side = isInside ? .inside : .outside
        guard watches[index].goesOff(seeing: side) else {
            var seen = watches
            seen[index].lastSide = side
            save(seen)
            return nil
        }
        return fired(id)
    }

    /// The reminder went off: it is no longer watched, and its card says so.
    func fired(_ id: String) -> PlaceWatch? {
        guard let watch = watches.first(where: { $0.id == id }) else {
            return nil
        }
        goneOff.insert(id)
        store.firedPlaceWatches = goneOff.sorted()
        save(watches.filter { $0.id != id })
        return watch
    }

    /// Pairing with another gateway: its cards are not this one's.
    func reset() {
        goneOff = []
        store.firedPlaceWatches = []
        save([])
    }

    private func save(_ next: [PlaceWatch]) {
        watches = next
        store.placeWatches = next
        onChange?()
    }
}
