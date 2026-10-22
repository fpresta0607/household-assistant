// Where the phone keeps the places it watches and the reminders that already went off,
// across launches: iOS starts the app in the background to say a place was crossed.
//
// A protocol because the phone keeps them in its settings and the tests keep them in memory.

import Foundation

@MainActor
protocol PlaceWatchStore: AnyObject {
    var placeWatches: [PlaceWatch] { get set }
    /// The message ids of reminders that went off, so their cards say so.
    var firedPlaceWatches: [String] { get set }
}
