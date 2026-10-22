// The owner's review of a clean-out batch: every photo starts ticked, the owner unticks what
// stays, and only the tap on Delete hands the ticked ones to iOS. Reviewing, ticking and
// unticking delete nothing.

import Foundation

struct CleanOutReview: Equatable, Sendable {
    let batch: CleanOutBatch
    /// The photos the owner unticked, which stay.
    private(set) var kept: Set<String> = []

    init(batch: CleanOutBatch) {
        self.batch = batch
    }

    func isChosen(_ id: String) -> Bool {
        batch.items.contains { $0.id == id } && !kept.contains(id)
    }

    mutating func toggle(_ id: String) {
        if kept.contains(id) {
            kept.remove(id)
        } else {
            kept.insert(id)
        }
    }

    /// Every photo of `reason` ticked, or unticked.
    mutating func choose(_ reason: CleanOutReason, isChosen: Bool) {
        let ids = batch.items(for: reason).map(\.id)
        if isChosen {
            kept.subtract(ids)
        } else {
            kept.formUnion(ids)
        }
    }

    /// The ticked photos, in the batch's order.
    var chosen: [String] {
        batch.items.map(\.id).filter { !kept.contains($0) }
    }

    /// The owner's tap on Delete: the ticked photos go to `deleter` in one call, and none when
    /// none is ticked. Says how many went.
    func delete(using deleter: PhotoDeleting) async throws -> Int {
        let ids = chosen
        guard !ids.isEmpty else {
            return 0
        }
        try await deleter.delete(ids)
        return ids.count
    }
}
