// Whether the connection banner shows.
//
// A link that drops and comes straight back is not news, and a phone back from the
// background often finds its socket gone and opens another in a second or two. So the
// banner says the link is coming up only once it has been down for `delaySeconds` with the
// app in front, and goes the moment the link is up. No link yet, as at launch before the
// first try, waits the same. Time in the background does not count: nobody was looking.
// What needs a person, an approval, a pairing or a failure, shows at once. Plain moments,
// so every rule is covered by a plain test.

import Foundation

struct ConnectionNotice: Equatable, Sendable {
    /// How long a link may be coming up before the banner says so.
    static let delaySeconds: Double = 3

    /// Whether the banner shows.
    private(set) var isShown = false
    /// When the banner held back for a link coming up shows, unless the link is up first:
    /// the one moment anybody has to look again.
    private(set) var dueAt: Date?

    private let delay: Double
    private var isLinkComingUp = false
    private var isInFront = true

    init(delaySeconds: Double = ConnectionNotice.delaySeconds) {
        delay = delaySeconds
    }

    /// The connection moved to `state` at `moment`. Another try while the link is already
    /// coming up keeps the time it went down.
    mutating func saw(_ state: ConnectionState, at moment: Date) {
        let isHeld = state.isComingUp || state == .disconnected
        if !isHeld {
            dueAt = nil
            isShown = state != .connected
        } else if !isLinkComingUp {
            hold(from: moment)
        }
        isLinkComingUp = isHeld
    }

    /// The app came to the front or went to the back. A link still coming up as it comes
    /// back gets its few seconds from then.
    mutating func moved(toFront: Bool, at moment: Date) {
        if toFront, !isInFront, isLinkComingUp {
            hold(from: moment)
        }
        isInFront = toFront
    }

    /// Looks again at `moment`: a banner held back shows once its time is up.
    mutating func look(at moment: Date) {
        if let dueAt, moment >= dueAt {
            isShown = true
            self.dueAt = nil
        }
    }

    private mutating func hold(from moment: Date) {
        isShown = false
        dueAt = moment.addingTimeInterval(delay)
        look(at: moment)
    }
}
