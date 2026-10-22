// A message this phone sends, as `household-app.send` takes it, signed by this phone.

import Foundation

struct RoomOutgoing: Equatable, Sendable {
    let conversation: RoomConversation
    let id: String
    /// Milliseconds since the epoch, when the person sent it.
    let at: Int
    let replyTo: String?
    let media: [RoomMedia]
    /// Where the person is, for a map they share. A map carries nothing attached.
    let location: SharedLocation?
    let text: String
    /// Whether it was said aloud on a call with the assistant. Sent beside the signed
    /// fields, never in them: it only asks the gateway for an answer made to be heard on
    /// that one turn, and grants nothing.
    let isCall: Bool
    /// This phone's signature over the message. Both conversations need it: the other
    /// gateway believes a family message only with it, and this gateway starts its owner's
    /// turn in the direct thread only from a message a paired phone signed.
    let signature: String

    /// Signs the message with `sign`, this phone's device key. Throws, and signs nothing,
    /// when a field other than the words would span two lines.
    init(
        conversation: RoomConversation,
        id: String,
        at: Int,
        replyTo: String?,
        media: [RoomMedia],
        location: SharedLocation? = nil,
        text: String,
        isCall: Bool = false,
        sign: (String) throws -> String
    ) throws {
        guard let signedText = RoomSignature.signedText(
            conversation: conversation,
            id: id,
            at: at,
            replyTo: replyTo,
            mediaIds: media.map(\.id),
            location: location,
            text: text
        ) else {
            throw GatewayErrorShape(code: "INVALID_REQUEST", message: "This message cannot be signed.", details: nil)
        }
        self.conversation = conversation
        self.id = id
        self.at = at
        self.replyTo = replyTo
        self.media = media
        self.location = location
        self.text = text
        self.isCall = isCall
        signature = try sign(signedText)
    }

    var params: JSONValue {
        var params: [String: JSONValue] = [
            "conversation": .string(conversation.rawValue),
            "id": .string(id),
            "at": .number(Double(at)),
            "replyTo": replyTo.map(JSONValue.string) ?? .null,
            "media": .array(media.map(\.json)),
            "text": .string(text),
            "signature": .string(signature),
        ]
        if let location {
            params["location"] = location.json
        }
        if isCall {
            params["call"] = .bool(true)
        }
        return .object(params)
    }
}
