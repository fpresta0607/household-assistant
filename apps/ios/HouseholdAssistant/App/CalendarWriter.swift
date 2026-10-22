// Puts an event card on the phone's calendar in one tap, without leaving the chat.
//
// The app asks iOS only to add events, never to read them (write-only access), and only
// the first time someone taps Add to Calendar. The event goes to the default calendar.

import EventKit
import Foundation

enum CalendarWriter {
    enum Failure: Error {
        case notAllowed
    }

    static func add(_ event: EventCard) async throws {
        let store = EKEventStore()
        guard try await store.requestWriteOnlyAccessToEvents() else {
            throw Failure.notAllowed
        }
        let entry = EKEvent(eventStore: store)
        entry.title = event.title
        entry.startDate = event.start
        entry.endDate = event.calendarEnd
        entry.location = event.location
        entry.calendar = store.defaultCalendarForNewEvents
        try store.save(entry, span: .thisEvent)
    }
}
