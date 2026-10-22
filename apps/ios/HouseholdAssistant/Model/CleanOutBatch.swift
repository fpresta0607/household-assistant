// The camera roll clean-out the photo keeper proposes: near-duplicates of the same shot past
// the best one, blurry shots, and screenshots older than a month, as one batch the owner
// reviews (CleanOutReview). Proposing deletes nothing. A favourite is never offered, and
// neither is a near-duplicate's best.

import Foundation

struct CleanOutBatch: Equatable, Sendable {
    /// How old a screenshot is before it is offered: one from this month may still be wanted.
    static let screenshotAge: TimeInterval = 30 * 86_400
    /// More than anyone reviews in one sitting; the rest wait for the next batch.
    static let most = 300

    let items: [CleanOutItem]

    /// The batch for `photos` as of `now`: each photo at most once, for the first reason that
    /// fits, near-duplicates first, newest photos first within each reason.
    static func propose(from photos: [PhotoFacts], now: Date) -> CleanOutBatch {
        var offered: [CleanOutItem] = []
        var seen = Set<String>()
        func offer(_ photo: PhotoFacts, _ reason: CleanOutReason, keptInstead: String? = nil) {
            guard !photo.isFavorite, seen.insert(photo.id).inserted else {
                return
            }
            offered.append(CleanOutItem(id: photo.id, reason: reason, keptInstead: keptInstead))
        }
        let newestFirst = photos.sorted { $0.takenAt > $1.takenAt }
        for group in NearDuplicates.groups(in: photos).reversed() {
            guard let best = NearDuplicates.best(of: group) else {
                continue
            }
            seen.insert(best.id)
            for photo in group.reversed() where photo.id != best.id {
                offer(photo, .duplicate, keptInstead: best.id)
            }
        }
        for photo in newestFirst where isBlurry(photo) {
            offer(photo, .blurry)
        }
        for photo in newestFirst where photo.isScreenshot && now.timeIntervalSince(photo.takenAt) > screenshotAge {
            offer(photo, .oldScreenshot)
        }
        return CleanOutBatch(items: Array(offered.prefix(most)))
    }

    /// Blurry by its edges and by Vision's eye both, so a calm sky or a soft portrait that
    /// Vision likes is never offered, and a screenshot is judged as a screenshot.
    static func isBlurry(_ photo: PhotoFacts) -> Bool {
        !photo.isScreenshot && !photo.isUtility && photo.sharpness < Sharpness.blurry && photo.score < 0
    }

    func items(for reason: CleanOutReason) -> [CleanOutItem] {
        items.filter { $0.reason == reason }
    }
}
