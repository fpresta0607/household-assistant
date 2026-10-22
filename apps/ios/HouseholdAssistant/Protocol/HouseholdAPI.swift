// The household-app plugin's gateway methods, typed. All need `operator.write` except
// `sync`, `history`, `media` and `apple.waiting`, which need `operator.read`; the phone
// holds both.

import Foundation

struct RoomUploadReceipt: Decodable, Equatable, Sendable {
    let complete: Bool
    let received: Int
    /// The attachment's hash, once the last chunk is in.
    let id: String?
    let bytes: Int?
}

struct RoomMediaChunk: Decodable, Equatable, Sendable {
    /// Base64.
    let data: String
    let offset: Int
    let total: Int
}

extension GatewayConnection {
    /// One upload or download chunk. Base64 makes it a third larger on the wire, which
    /// keeps a frame far under the gateway's 25 MiB ceiling.
    nonisolated static let roomChunkBytes = 256 * 1024

    func roomSync(since: Int, limit: Int = 500) async throws -> RoomSyncPage {
        try await request("household-app.sync", .object([
            "since": .number(Double(since)),
            "limit": .number(Double(limit)),
        ]), as: RoomSyncPage.self)
    }

    func roomHistory(_ conversation: RoomConversation, before: Int?, limit: Int = 100) async throws -> RoomHistoryPage {
        var params: [String: JSONValue] = [
            "conversation": .string(conversation.rawValue),
            "limit": .number(Double(limit)),
        ]
        if let before {
            params["before"] = .number(Double(before))
        }
        return try await request("household-app.history", .object(params), as: RoomHistoryPage.self)
    }

    /// `roomSync`, with the gateway's JSON beside the page, for the phone to keep.
    func roomSyncKept(since: Int, limit: Int = 500) async throws -> KeptAnswer<RoomSyncPage> {
        try await request("household-app.sync", .object([
            "since": .number(Double(since)),
            "limit": .number(Double(limit)),
        ]), as: KeptAnswer<RoomSyncPage>.self)
    }

    /// The newest page of a conversation, with the gateway's JSON beside it, for the phone
    /// to keep.
    func roomNewestKept(_ conversation: RoomConversation, limit: Int = 100) async throws -> KeptAnswer<RoomHistoryPage> {
        try await request("household-app.history", .object([
            "conversation": .string(conversation.rawValue),
            "limit": .number(Double(limit)),
        ]), as: KeptAnswer<RoomHistoryPage>.self)
    }

    /// Returns once the gateway has kept the message. Whether the assistant answers is
    /// decided after that, and its reply arrives as a change.
    func roomSend(_ message: RoomOutgoing) async throws -> RoomEntry {
        let payload = try await request("household-app.send", message.params)
        guard let entry = payload["entry"] else {
            throw GatewayConnectionError.unexpectedFrame
        }
        return try entry.decoded(as: RoomEntry.self)
    }

    /// A call that ended, folded by the gateway into one entry with its words, which it
    /// answers with. `signature` is over `RoomSignature.callEndText`, and `setup`, how the
    /// call came up, rides beside what is signed for the gateway's log alone.
    func roomCallEnd(callId: String, startedAt: Int, endedAt: Int, turns: [String], signature: String, setup: CallSetup) async throws -> RoomEntry {
        let payload = try await request("household-app.call.end", .object([
            "callId": .string(callId),
            "startedAt": .number(Double(startedAt)),
            "endedAt": .number(Double(endedAt)),
            "turns": .array(turns.map(JSONValue.string)),
            "signature": .string(signature),
            "setup": setup.params,
        ]))
        guard let entry = payload["entry"] else {
            throw GatewayConnectionError.unexpectedFrame
        }
        return try entry.decoded(as: RoomEntry.self)
    }

    func roomUpload(uploadId: String, offset: Int, total: Int, data: Data) async throws -> RoomUploadReceipt {
        try await request("household-app.upload", .object([
            "uploadId": .string(uploadId),
            "offset": .number(Double(offset)),
            "total": .number(Double(total)),
            "data": .string(data.base64EncodedString()),
        ]), as: RoomUploadReceipt.self)
    }

    func roomMedia(id: String, offset: Int, length: Int = roomChunkBytes) async throws -> RoomMediaChunk {
        try await request("household-app.media", .object([
            "id": .string(id),
            "offset": .number(Double(offset)),
            "length": .number(Double(length)),
        ]), as: RoomMediaChunk.self)
    }

    /// Nil takes this phone owner's reaction back.
    func roomReact(messageId: String, emoji: String?) async throws {
        _ = try await request("household-app.react", .object([
            "messageId": .string(messageId),
            "emoji": emoji.map(JSONValue.string) ?? .null,
        ]))
    }

    /// Ticks or unticks one item of an assistant's checklist card. The gateway keeps it for
    /// the assistant to read at the start of its next turn.
    func roomTick(_ tick: ChecklistTick, isDone: Bool, in conversation: RoomConversation) async throws {
        _ = try await request("household-app.card.tick", .object([
            "conversation": .string(conversation.rawValue),
            "messageId": .string(tick.messageId),
            "cardId": .string(tick.cardId),
            "item": .number(Double(tick.item)),
            "done": .bool(isDone),
        ]))
    }

    /// Says the items on a cart card were ordered, by whoever checked out. The gateway
    /// takes them out of the cart, posts the cart as it now stands and, in the buyer's own
    /// thread, the order, and answers how many items it marked.
    func roomCartOrdered(messageId: String, in conversation: RoomConversation) async throws -> Int {
        let payload = try await request("household-app.cart.ordered", .object([
            "conversation": .string(conversation.rawValue),
            "messageId": .string(messageId),
        ]))
        guard let ordered = payload["ordered"]?.intValue else {
            throw GatewayConnectionError.unexpectedFrame
        }
        return ordered
    }

    /// Answers an approval card in this phone's own thread. `signature` is this phone's
    /// signature of `ApprovalAnswer.signedText`. How the card ended arrives as a change.
    func roomAnswerApproval(messageId: String, decision: RoomApproval.Decision, signature: String) async throws {
        _ = try await request("household-app.approval.answer", .object([
            "messageId": .string(messageId),
            "decision": .string(decision.rawValue),
            "signature": .string(signature),
        ]))
    }

    func roomRead(_ conversation: RoomConversation, messageId: String) async throws {
        _ = try await request("household-app.read", .object([
            "conversation": .string(conversation.rawValue),
            "messageId": .string(messageId),
        ]))
    }

    /// Whether this phone's person is typing in a conversation, for the others in it.
    func roomTyping(_ conversation: RoomConversation, isActive: Bool) async throws {
        _ = try await request("household-app.typing", .object([
            "conversation": .string(conversation.rawValue),
            "active": .bool(isActive),
        ]))
    }

    /// `key` is the 32-byte AES key, base64, that this phone's notifications are sealed under.
    func roomRegisterPush(token: String, environment: String, key: String) async throws {
        _ = try await request("household-app.push.register", .object([
            "token": .string(token),
            "environment": .string(environment),
            "key": .string(key),
        ]))
    }

    /// Where this phone is, or that its person stopped sharing it, for its own gateway only.
    /// `signature` is this phone's signature of `report.signedText`.
    func roomLocation(_ report: LocationReport, signature: String) async throws {
        _ = try await request("household-app.location", report.params(signature: signature))
    }

    /// What iOS measured of the app over about a day, for the gateway's own log.
    func reportPhoneMetrics(_ metrics: PhoneMetrics) async throws {
        _ = try await request("household-app.metrics.report", metrics.params)
    }

    /// Moves a live map this phone shared, or stops it. `signature` is this phone's
    /// signature of `update.signedText`. The gateway refuses a move once the share has
    /// ended or stopped, and one no newer than the last.
    func roomLive(_ update: LiveLocationUpdate, signature: String) async throws {
        _ = try await request("household-app.location.live", update.params(signature: signature))
    }

    /// This phone's person's yes or no to a reminder by place in the family room that would
    /// watch them. `signature` is this phone's signature of `PlaceAnswer.signedText`.
    func roomAnswerPlace(messageId: String, answer: PlaceAnswer, at: Int, signature: String) async throws {
        _ = try await request("household-app.place.answer", .object([
            "messageId": .string(messageId),
            "answer": .string(answer.rawValue),
            "at": .number(Double(at)),
            "signature": .string(signature),
        ]))
    }

    /// This phone's person's face, or their assistant's, from a photo already uploaded.
    /// The gateway answers with everyone in the room, faces included.
    func roomSetAvatar(participant: String, media: RoomMedia) async throws -> [RoomParticipant] {
        let payload = try await request("household-app.avatar.set", .object([
            "participant": .string(participant),
            "media": media.json,
        ]))
        guard let participants = payload["participants"] else {
            throw GatewayConnectionError.unexpectedFrame
        }
        return try participants.decoded(as: [RoomParticipant].self)
    }

    /// The colour of the ring round the family room's face, nil for its own white edge,
    /// which both phones show, with this phone's person's line in the room for it. The
    /// gateway answers with the look it now holds.
    func roomSetLookColor(_ ring: RingColor?) async throws -> FamilyLook {
        let color: JSONValue = ring.map { .object(["red": .number($0.red), "green": .number($0.green), "blue": .number($0.blue)]) } ?? .null
        return try await setLook(["change": .string("color"), "ring": color])
    }

    /// The family room's appearance, and with Custom the background it is drawn on, nil to
    /// keep the latest one, the same way as the colour.
    func roomSetLookAppearance(_ appearance: FamilyLook.Appearance, background: ChatBackground?) async throws -> FamilyLook {
        var params: [String: JSONValue] = ["change": .string("appearance"), "appearance": .string(appearance.rawValue)]
        if let background {
            params["background"] = .string(background.rawValue)
        }
        return try await setLook(params)
    }

    private func setLook(_ params: [String: JSONValue]) async throws -> FamilyLook {
        guard let look = try await request("household-app.look.set", .object(params))["familyLook"] else {
            throw GatewayConnectionError.unexpectedFrame
        }
        return try look.decoded(as: FamilyLook.self)
    }

    /// A nonce for linking this phone's person's Apple ID, single use, for ten minutes.
    func appleNonce() async throws -> String {
        guard let nonce = try await request("household-app.apple.nonce")["nonce"]?.stringValue else {
            throw GatewayConnectionError.unexpectedFrame
        }
        return nonce
    }

    /// From now on, signing in with this Apple ID pairs a new phone as this one's person.
    func appleLink(identityToken: String, nonce: String) async throws {
        _ = try await request("household-app.apple.link", .object([
            "identityToken": .string(identityToken),
            "nonce": .string(nonce),
        ]))
    }

    /// Who waits for the approver on either gateway. Empty on anybody else's phone.
    func appleWaiting() async throws -> [AppleSignInRequest] {
        guard let waiting = try await request("household-app.apple.waiting")["waiting"] else {
            throw GatewayConnectionError.unexpectedFrame
        }
        return try waiting.decoded(as: [AppleSignInRequest].self)
    }

    /// `signature` is this phone's signature of `AppleApproval.signedText`.
    func appleApprove(requestId: String, person: String, at: Int, signature: String) async throws {
        _ = try await request("household-app.apple.approve", .object([
            "requestId": .string(requestId),
            "person": .string(person),
            "at": .number(Double(at)),
            "signature": .string(signature),
        ]))
    }
}
