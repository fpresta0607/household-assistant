// One position iOS measured: where, to within how many metres, when, and whether it was
// a visit, arriving somewhere or leaving it, rather than a move. iOS gives it precise or
// approximate as its person allowed there, and the accuracy says which.

import Foundation

struct LocationFix: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    /// Metres. Negative when iOS could not measure it.
    let accuracy: Double
    let at: Date
    var isVisit = false

    private static let earthRadiusMetres = 6_371_008.8
    /// The side of the square an approximate position stands for: about a neighbourhood.
    static let neighbourhoodMetres = 2_000.0

    /// The great-circle distance to another position, in metres.
    func distance(to other: LocationFix) -> Double {
        let degree: Double = .pi / 180
        let halfLatitude: Double = sin((other.latitude - latitude) * degree / 2)
        let halfLongitude: Double = sin((other.longitude - longitude) * degree / 2)
        let across: Double = cos(latitude * degree) * cos(other.latitude * degree)
        let half: Double = halfLatitude * halfLatitude + across * halfLongitude * halfLongitude
        return 2 * Self.earthRadiusMetres * asin(min(1, sqrt(half)))
    }

    /// Only the neighbourhood: the middle of the two-kilometre square of a fixed grid that
    /// the position falls in, so every position in it reads the same and the exact one
    /// never leaves the phone. What Precise Location off sends.
    var approximated: LocationFix {
        let latitudeStep = Self.neighbourhoodMetres / (Self.earthRadiusMetres * .pi / 180)
        let middleLatitude = ((latitude / latitudeStep).rounded(.down) + 0.5) * latitudeStep
        // A degree of longitude is shorter away from the equator, so the squares are wider
        // in degrees there, the same width in metres.
        let longitudeStep = latitudeStep / max(cos(middleLatitude * .pi / 180), 0.01)
        let middleLongitude = ((longitude / longitudeStep).rounded(.down) + 0.5) * longitudeStep
        return LocationFix(
            latitude: middleLatitude,
            longitude: middleLongitude,
            accuracy: accuracy < 0 ? accuracy : max(accuracy, Self.neighbourhoodMetres),
            at: at,
            isVisit: isVisit
        )
    }

    /// As the gateway takes it, in whole units.
    var position: LocationReport.Position {
        LocationReport.Position(
            latitudeE6: Int((latitude * 1_000_000).rounded()),
            longitudeE6: Int((longitude * 1_000_000).rounded()),
            accuracy: Int(accuracy.rounded(.up)),
            at: Int((at.timeIntervalSince1970 * 1000).rounded())
        )
    }
}
