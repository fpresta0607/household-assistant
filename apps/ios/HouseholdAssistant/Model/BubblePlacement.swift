// Where each bubble sits in the thread.
//
// Consecutive messages from one voice form a run: the first carries the
// sender's name, the last carries the tail, and the runs are spaced apart
// while the bubbles inside one sit close. A time goes above a message when an
// hour or more has passed since the one before it, and that also starts a run.

import Foundation

struct BubblePlacement: Equatable, Sendable {
    let startsRun: Bool
    let endsRun: Bool
    /// The time to show above this bubble, if one belongs there.
    let divider: Date?

    static let dividerGap: TimeInterval = 60 * 60

    static func placements(for messages: [RoomMessage]) -> [BubblePlacement] {
        var dividers: [Date?] = []
        var lastSentAt: Date?
        for message in messages {
            let isAfterAGap = lastSentAt.map { message.sentAt.timeIntervalSince($0) >= dividerGap } ?? true
            dividers.append(isAfterAGap ? message.sentAt : nil)
            lastSentAt = message.sentAt
        }
        return messages.indices.map { index in
            let startsRun = index == messages.startIndex
                || messages[index - 1].author != messages[index].author
                || dividers[index] != nil
            let isLast = index == messages.index(before: messages.endIndex)
            let endsRun = isLast
                || messages[index + 1].author != messages[index].author
                || dividers[index + 1] != nil
            return BubblePlacement(startsRun: startsRun, endsRun: endsRun, divider: dividers[index])
        }
    }
}
