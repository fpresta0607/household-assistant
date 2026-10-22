// Watches where this phone is while its person shares it, and only then.
//
// iOS wakes the app for a significant change, about half a kilometre, and for a visit,
// arriving somewhere or leaving it: never a stream, and with Always allowed, even with the
// app closed. One fresh position is asked for when sharing starts or the app comes forward.
// Nothing here asks Apple's servers anything: no addresses looked up and no maps drawn.

import CoreLocation
import Foundation

@MainActor
final class LocationWatcher: NSObject, CLLocationManagerDelegate {
    /// A position iOS measured.
    var onFix: ((LocationFix) -> Void)?
    /// iOS no longer lets the app use location: the person took it away in iOS Settings, or
    /// an Allow Once ran out. Told once when the watcher is made, and on every change.
    var onDenied: (() -> Void)?

    /// Off in the screenshot tests and the demo, which have no location to watch.
    private let isAllowedToWatch: Bool
    private let manager = CLLocationManager()
    private var isWatching = false

    init(isAllowedToWatch: Bool) {
        self.isAllowedToWatch = isAllowedToWatch
        super.init()
        manager.delegate = self
    }

    /// Watches while `isSharing`, and asks for a fresh position each time it is told so.
    func follow(isSharing: Bool) {
        guard isAllowedToWatch else {
            return
        }
        guard isSharing else {
            if isWatching {
                manager.stopMonitoringSignificantLocationChanges()
                manager.stopMonitoringVisits()
                isWatching = false
            }
            return
        }
        if !isWatching {
            manager.startMonitoringSignificantLocationChanges()
            manager.startMonitoringVisits()
            isWatching = true
        }
        manager.requestLocation()
    }

    // The manager was made on the main thread, so iOS calls these there.

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard let newest = locations.max(by: { $0.timestamp < $1.timestamp }) else {
                return
            }
            onFix?(LocationFix(
                latitude: newest.coordinate.latitude,
                longitude: newest.coordinate.longitude,
                accuracy: newest.horizontalAccuracy,
                at: newest.timestamp
            ))
        }
    }

    /// An arrival or a departure: the place, as of the moment it happened.
    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        MainActor.assumeIsolated {
            let happened = visit.departureDate != .distantFuture ? visit.departureDate : visit.arrivalDate
            onFix?(LocationFix(
                latitude: visit.coordinate.latitude,
                longitude: visit.coordinate.longitude,
                accuracy: visit.horizontalAccuracy,
                at: happened == .distantPast ? Date() : min(happened, Date()),
                isVisit: true
            ))
        }
    }

    /// A position iOS could not get this time. The next move or visit tries again.
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            switch manager.authorizationStatus {
            case .denied, .restricted, .notDetermined:
                if isAllowedToWatch {
                    onDenied?()
                }
            default:
                break
            }
        }
    }
}
