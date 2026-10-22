// Where the phone keeps the live maps it still moves, across launches, and its Precise
// Location switch, which a live map follows as the assistant's sharing does.
//
// A protocol because the phone keeps them in its settings and the tests keep them in memory.

import Foundation

@MainActor
protocol LiveShareStore: AnyObject {
    var liveShares: [LiveShare] { get set }
    /// Off, only the neighbourhood is sent.
    var isLocationPrecise: Bool { get }
}
