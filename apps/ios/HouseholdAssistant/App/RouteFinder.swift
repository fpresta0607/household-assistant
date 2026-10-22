// The way to a map card's place from where this phone is, worked out by Apple Maps on the
// phone. Apple sees where the phone is for that, as Maps itself would; the gateway never
// does.

import CoreLocation
import Foundation
import MapKit

@MainActor
enum RouteFinder {
    enum Failure: LocalizedError {
        case noWay

        var errorDescription: String? {
            "Apple Maps found no way there from here."
        }
    }

    static func route(to card: MapCard) async throws -> MapRoute {
        let request = MKDirections.Request()
        request.source = MKMapItem.forCurrentLocation()
        request.destination = MKMapItem(location: CLLocation(latitude: card.center.latitude, longitude: card.center.longitude), address: nil)
        request.transportType = card.route == .walking ? .walking : .automobile
        guard let route = try await MKDirections(request: request).calculate().routes.first else {
            throw Failure.noWay
        }
        var coordinates = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: route.polyline.pointCount)
        route.polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: route.polyline.pointCount))
        return MapRoute(
            points: coordinates.map { MapPoint(latitude: $0.latitude, longitude: $0.longitude) },
            seconds: route.expectedTravelTime,
            metres: route.distance,
            name: route.name
        )
    }
}
