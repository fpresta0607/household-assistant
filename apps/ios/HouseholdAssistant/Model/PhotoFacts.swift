// What the photo keeper knows of one photo in the person's library, read on this phone from
// a small thumbnail (PhotoKeeperScanner) and never sent anywhere: when it was taken, whether
// iOS calls it a screenshot or a favourite, how sharp it is, how good Vision thinks it looks,
// what it shows, and its feature print, which says how alike two photos are.

import Foundation

struct PhotoFacts: Equatable, Sendable, Identifiable {
    /// The photo's local identifier in the library.
    let id: String
    let takenAt: Date
    let isScreenshot: Bool
    let isFavorite: Bool
    /// The variance of the thumbnail's Laplacian (Sharpness): low is blurry.
    let sharpness: Double
    /// Vision's overall aesthetics score, from -1 to 1.
    let score: Double
    /// Whether Vision reads it as a utility shot, such as a receipt, a document or a whiteboard.
    let isUtility: Bool
    /// What it shows, Vision's surest labels, such as "cat" or "beach".
    let scenes: [String]
    /// Vision's feature print, as floats.
    let print: [Float]

    /// How unlike `other` it looks: the distance between the two feature prints, which Vision
    /// measures the same way. Prints of different lengths are as unlike as can be.
    func distance(to other: PhotoFacts) -> Double {
        guard print.count == other.print.count, !print.isEmpty else {
            return .infinity
        }
        var sum: Double = 0
        for index in print.indices {
            let difference = Double(print[index] - other.print[index])
            sum += difference * difference
        }
        return sum.squareRoot()
    }
}
