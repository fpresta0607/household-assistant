// Photos that are the same shot more or less: taken within moments of each other and alike
// by their feature prints, such as a burst, or the five tries at one group photo. Each group
// keeps its best and offers the rest to the clean-out (CleanOutBatch), and a recap shows
// only its best (MonthlyRecap).

import Foundation

enum NearDuplicates {
    /// How close in time two photos of one shot are taken.
    static let window: TimeInterval = 120
    /// How alike two feature prints are for the same shot. Vision's prints of one scene a
    /// moment apart sit well under it; two different scenes sit well over it.
    static let distance: Double = 0.35

    /// The groups of two or more, each in the order taken. A photo joins a group when it is
    /// alike, and close in time, to the group's last photo, so a slow pan never chains two
    /// unlike ends together beyond the window.
    static func groups(in photos: [PhotoFacts]) -> [[PhotoFacts]] {
        var groups: [[PhotoFacts]] = []
        var current: [PhotoFacts] = []
        for photo in photos.sorted(by: { $0.takenAt < $1.takenAt }) {
            if let last = current.last,
               photo.takenAt.timeIntervalSince(last.takenAt) <= window,
               photo.distance(to: last) <= distance {
                current.append(photo)
                continue
            }
            if current.count > 1 {
                groups.append(current)
            }
            current = [photo]
        }
        if current.count > 1 {
            groups.append(current)
        }
        return groups
    }

    /// How good a photo is to keep: a favourite first, then Vision's score, then sharpness.
    static func rank(_ photo: PhotoFacts) -> Double {
        (photo.isFavorite ? 10 : 0) + photo.score + min(photo.sharpness, 1000) / 10000
    }

    /// The photo of `group` to keep.
    static func best(of group: [PhotoFacts]) -> PhotoFacts? {
        group.max { rank($0) < rank($1) }
    }
}
