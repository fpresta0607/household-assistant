// A call with the assistant as its thread shows it once it ended: one row saying who, how
// long and when, which opens what was said. The gateway folds the call's messages into it,
// so they never show one by one.

import Foundation

struct RoomCall: Equatable, Sendable {
    let startedAt: Date
    let endedAt: Date
    /// The assistant the call was with.
    let assistant: String
    /// The messages the call's words were said in, which this row stands for.
    let turnIds: [String]
    let transcript: [CallTranscriptLine]
    /// Whether only the start of a long call's words was kept.
    let isCut: Bool

    /// Nil for any entry that is not a whole call.
    init?(_ entry: RoomEntry) {
        guard entry.kind == .call, let endedAt = entry.endedAt, let callee = entry.callee else {
            return nil
        }
        startedAt = entry.sentAt
        self.endedAt = Date(timeIntervalSince1970: Double(endedAt) / 1000)
        assistant = callee
        turnIds = entry.turnIds
        transcript = entry.transcript
        isCut = entry.isCut
    }

    /// The messages a call's words were said in, for the gateway to fold into its entry:
    /// each turn the person said that the gateway kept, and the kept reply to it. A reply
    /// still arriving when the call ends stays a message of its own.
    static func turnIds(asked: [String], in thread: RoomThread, assistant: String?) -> [String] {
        var turns: [String] = []
        for id in asked where thread.messages.contains(where: { $0.id == id && $0.rev != nil }) {
            turns.append(id)
            if let assistant, let reply = thread.reply(to: id, from: assistant), reply.rev != nil, !turns.contains(reply.id), !asked.contains(reply.id) {
                turns.append(reply.id)
            }
        }
        return turns
    }

    /// How long it lasted, in whole seconds.
    var seconds: Int {
        max(0, Int(endedAt.timeIntervalSince(startedAt).rounded()))
    }

    /// "4:07", or "1:02:09" past an hour, as the Phone app's recents say it.
    var length: String {
        let hours = seconds / 3600
        let minutes = seconds / 60 % 60
        let rest = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}
