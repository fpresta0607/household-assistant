// The regions the map cards draw: round one place, or holding a whole way there.

import MapKit

extension MKCoordinateRegion {
    /// A region round `place` `metres` across.
    init(around place: MapPoint, metres: Double) {
        self.init(
            center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
            latitudinalMeters: metres,
            longitudinalMeters: metres
        )
    }

    /// The smallest region that holds every one of `places` with a margin round them, and
    /// at least `metres` across.
    init(holding places: [MapPoint], atLeast metres: Double) {
        let latitudes = places.map(\.latitude)
        let longitudes = places.map(\.longitude)
        let south = latitudes.min() ?? 0
        let north = latitudes.max() ?? 0
        let west = longitudes.min() ?? 0
        let east = longitudes.max() ?? 0
        self.init(around: MapPoint(latitude: (south + north) / 2, longitude: (west + east) / 2), metres: metres)
        span.latitudeDelta = max(span.latitudeDelta, (north - south) * 1.4)
        span.longitudeDelta = max(span.longitudeDelta, (east - west) * 1.4)
    }
}
