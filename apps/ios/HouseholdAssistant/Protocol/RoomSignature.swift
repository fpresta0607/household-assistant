// What this phone signs when it says something, in the family room or its own thread.
//
// The other gateway believes a family message came from this phone's owner only when
// the device key this phone pairs with signed it, and this gateway starts its owner's
// turn in the direct thread only for a message one of the owner's phones signed. The
// text is one line per field with the words last, exactly as
// deploy/openclaw/plugins/household-app/signature.js builds it, so a newline in the
// words cannot be read as a field boundary.
//
// A map is signed under a version line of its own, with its place and end in place of the
// attachments, so a message signed without a place can never be given one.
//
// A call's end is signed under one more: the call, when it started and ended, and the
// messages its words were said in, which the gateway then folds into one entry. Only a
// phone of the owner's can have the owner's thread lose those messages that way.

import Foundation

enum RoomSignature {
    static let version = "household-app/v1"
    static let mapVersion = "household-app/map/v1"
    static let callVersion = "household-app/call/v1"

    /// Nil when a field other than the words would span two lines.
    static func signedText(
        conversation: RoomConversation,
        id: String,
        at: Int,
        replyTo: String?,
        mediaIds: [String],
        location: SharedLocation? = nil,
        text: String
    ) -> String? {
        let head = [conversation.rawValue, id, String(at), replyTo ?? ""]
        let fields: [String]
        if let location {
            let place = [location.latitudeE6, location.longitudeE6, location.accuracy, location.at].map(String.init)
            fields = head + [location.until.map(String.init) ?? ""] + place
        } else {
            fields = head + [mediaIds.joined(separator: ",")]
        }
        guard fields.allSatisfy({ !$0.contains("\n") && !$0.contains("\r") }) else {
            return nil
        }
        return ([location == nil ? version : mapVersion] + fields + [text]).joined(separator: "\n")
    }

    /// What a call's end signs: the call, its start and end in milliseconds, and its
    /// messages' ids. Nil when an id would span two lines or hold a comma.
    static func callEndText(callId: String, startedAt: Int, endedAt: Int, turns: [String]) -> String? {
        guard ([callId] + turns).allSatisfy({ !$0.contains("\n") && !$0.contains("\r") && !$0.contains(",") }) else {
            return nil
        }
        return [callVersion, callId, String(startedAt), String(endedAt), turns.joined(separator: ",")].joined(separator: "\n")
    }
}
