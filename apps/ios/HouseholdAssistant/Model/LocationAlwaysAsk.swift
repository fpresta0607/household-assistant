// When the app asks iOS for Always: at the moment the person turns on something that must
// go on with the app closed.
//
// - Sharing with their assistant, or the family room too, that lasts, from the first run
//   or Settings: iOS then wakes the app for a significant move or a visit while it is
//   closed. On a first ask iOS shows only its usual While Using question, and offers
//   Always by itself once the app first reports in the background, so it costs no extra
//   question.
// - A map in a chat that stays live for a while. A map shared once stays While Using.
// - A reminder by place, their own or one they said yes to, which iOS watches.
//
// A no to Always keeps everything working while the app is open, and Location says
// plainly that sharing pauses when the app is closed.

import Foundation

enum LocationAlwaysAsk {
    enum Moment: Equatable, Sendable {
        case sharingTurnedOn(LocationSpan)
        case mapShared(MapShareSpan)
        case placeReminderSet
    }

    static func isAsked(at moment: Moment) -> Bool {
        switch moment {
        case .sharingTurnedOn:
            return true
        case .mapShared(let span):
            return span != .once
        case .placeReminderSet:
            return true
        }
    }

    /// What Location says while sharing runs without Always: that it pauses when the app is
    /// closed, and how to keep it going. Nil when it does not pause.
    static func closedAppNote(sharing: LocationSharing?, isAlways: Bool, at now: Date) -> String? {
        guard let sharing, sharing.isSending(at: now), !isAlways else {
            return nil
        }
        return "It pauses when Steward AI is closed. Choose Always for Steward AI in iOS Settings to keep it going."
    }
}
