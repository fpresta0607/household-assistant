// Where a place falls on a map picture (MapSnapshot), so a card can put a face, a pin,
// the way there or a circle exactly on it.

import CoreLocation
import SwiftUI

struct MapProjection {
    let locate: (CLLocationCoordinate2D) -> CGPoint

    func point(_ place: MapPoint) -> CGPoint {
        locate(CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude))
    }

    /// How many points `metres` span on the picture at `place`, for a circle round it.
    func span(metres: Double, at place: MapPoint) -> CGFloat {
        let north = MapPoint(latitude: place.latitude + metres / 111_195, longitude: place.longitude)
        return abs(point(place).y - point(north).y)
    }
}
