// Where the phone keeps its person's choice about sharing where they are, across
// launches: iOS can start the app in the background to say it moved.
//
// A protocol because the phone keeps it in its settings and the tests keep it in memory.

import Foundation

@MainActor
protocol LocationSharingStore: AnyObject {
    /// Nil while off.
    var locationSharing: LocationSharing? { get set }
    /// True from the moment a position is sent until a stop reaches the gateway, so a stop
    /// that did not get through is sent again, even after the app was closed.
    var isLocationHeldByGateway: Bool { get set }
    /// Precise Location, the app's own switch: off, only the neighbourhood is sent. A
    /// choice for this iPhone, kept while sharing is off too.
    var isLocationPrecise: Bool { get set }
}
