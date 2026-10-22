// The live maps this phone shared, moved while they last.
//
// Once the gateway has kept a live map, the phone follows where it is (the app's live
// location feed) and moves the map when the move is worth it (LiveShareRule), with an
// update signed by this phone's device key, as the map itself was. It stops by itself when
// the time chosen is up, and the person can stop it sooner, which sends a stop so the
// gateway takes no more. With Precise Location off, only the neighbourhood moves.
//
// Nothing is sent to anyone but this phone's own gateway, which keeps the newest move and
// hands it to the conversation, and to the other gateway for the family room.

import Foundation
import Observation

@MainActor
@Observable
final class LiveShareModel {
    /// Why the last move did not reach the gateway, in the gateway's words.
    private(set) var errorText: String?

    @ObservationIgnored private let connection: GatewayConnection
    @ObservationIgnored private let sign: (String) throws -> String
    @ObservationIgnored private let store: LiveShareStore
    @ObservationIgnored private let now: () -> Date
    /// The last position each map was moved to, as sent, by message id.
    @ObservationIgnored private var lastSent: [String: LocationFix] = [:]
    /// When each map's newest update was signed: the gateway takes only a newer one.
    @ObservationIgnored private var lastAt: [String: Int] = [:]
    /// Told whenever a share starts or ends, so the phone follows its position exactly
    /// while one is live.
    @ObservationIgnored var onChange: (() -> Void)?

    init(connection: GatewayConnection, sign: @escaping (String) throws -> String, store: LiveShareStore, now: @escaping () -> Date = Date.init) {
        self.connection = connection
        self.sign = sign
        self.store = store
        self.now = now
    }

    /// The shares still running.
    var shares: [LiveShare] {
        store.liveShares
    }

    /// Whether the phone follows its position now.
    var isFollowing: Bool {
        shares.contains { !$0.isOver(at: now()) }
    }

    func isSharing(_ messageId: String) -> Bool {
        shares.contains { $0.messageId == messageId && !$0.isOver(at: now()) }
    }

    /// A live map the gateway kept: `fix` is where it was shared from, as sent, and
    /// `sentAt` the map message's own time, which every update comes after.
    func start(_ share: LiveShare, at fix: LocationFix, sentAt: Int) {
        store.liveShares = store.liveShares.filter { $0.messageId != share.messageId } + [share]
        lastSent[share.messageId] = fix
        lastAt[share.messageId] = sentAt
        onChange?()
    }

    /// A position from iOS: each live map that should move, moves.
    func consider(_ fix: LocationFix) async {
        endIfOver()
        let told = store.isLocationPrecise ? fix : fix.approximated
        for share in shares where LiveShareRule.shouldSend(told, after: lastSent[share.messageId]) {
            let update = LiveLocationUpdate(messageId: share.messageId, at: nextAt(for: share.messageId), position: told.position)
            if await deliver(update) {
                lastSent[share.messageId] = told
            }
        }
    }

    /// Stops a live map before its time. Answers whether the gateway took the stop; one
    /// it refuses, because the share already ended, is forgotten all the same.
    @discardableResult
    func stop(_ messageId: String) async -> Bool {
        guard shares.contains(where: { $0.messageId == messageId }) else {
            return false
        }
        let isStopped = await deliver(LiveLocationUpdate(messageId: messageId, at: nextAt(for: messageId), position: nil))
        if isStopped {
            forget(messageId)
        }
        return isStopped
    }

    /// Forgets every share whose time is up. The gateway needs no word: it knows the end.
    func endIfOver() {
        let over = shares.filter { $0.isOver(at: now()) }
        guard !over.isEmpty else {
            return
        }
        for share in over {
            forget(share.messageId)
        }
    }

    /// Pairing with another gateway: its maps are not this one's to move.
    func reset() {
        store.liveShares = []
        lastSent = [:]
        lastAt = [:]
        errorText = nil
        onChange?()
    }

    private func forget(_ messageId: String) {
        store.liveShares = store.liveShares.filter { $0.messageId != messageId }
        lastSent[messageId] = nil
        lastAt[messageId] = nil
        onChange?()
    }

    /// Sent and kept, or not. A refusal means the gateway will take no more for that map,
    /// so it is forgotten; a link that is down keeps it for the next position.
    private func deliver(_ update: LiveLocationUpdate) async -> Bool {
        do {
            guard let text = update.signedText else {
                throw GatewayErrorShape(code: "INVALID_REQUEST", message: "This move cannot be signed.", details: nil)
            }
            try await connection.roomLive(update, signature: try sign(text))
            errorText = nil
            return true
        } catch let refusal as GatewayErrorShape where refusal.code == "INVALID_REQUEST" {
            errorText = refusal.message
            forget(update.messageId)
            return false
        } catch {
            errorText = ErrorText.describe(error)
            return false
        }
    }

    /// Now, or a millisecond after the last update if the clock has not moved on since.
    private func nextAt(for messageId: String) -> Int {
        let next = max(Int((now().timeIntervalSince1970 * 1000).rounded()), (lastAt[messageId] ?? 0) + 1)
        lastAt[messageId] = next
        return next
    }
}
