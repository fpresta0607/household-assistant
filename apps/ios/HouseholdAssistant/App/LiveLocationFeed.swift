// Where this phone is, second by second, while it moves a live map, and one fresh
// position when a map is shared: iOS 17's live updates. A background activity session
// keeps them coming with the app in the background, with iOS's blue pill showing, and
// only for as long as a live map lasts.
//
// Nothing here asks Apple's servers anything: no address is looked up.

import CoreLocation
import Foundation

@MainActor
final class LiveLocationFeed {
    /// A position iOS measured while a live map lasts.
    var onFix: ((LocationFix) -> Void)?

    /// Off in the screenshot tests and the demo, which have no position to follow.
    private let isAllowedToFollow: Bool
    private var following: Task<Void, Never>?
    private var session: CLBackgroundActivitySession?

    /// The vaguest position a map is shared from.
    private nonisolated static let widestAccuracyMetres: CLLocationAccuracy = 1000

    init(isAllowedToFollow: Bool) {
        self.isAllowedToFollow = isAllowedToFollow
    }

    /// Follows the position while `isFollowing`, and stops the moment it is not.
    func follow(_ isFollowing: Bool) {
        guard isAllowedToFollow else {
            return
        }
        guard isFollowing else {
            following?.cancel()
            following = nil
            session?.invalidate()
            session = nil
            return
        }
        guard following == nil else {
            return
        }
        session = CLBackgroundActivitySession()
        following = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    guard !Task.isCancelled else {
                        return
                    }
                    if let location = update.location, location.horizontalAccuracy > 0 {
                        self?.onFix?(Self.fix(location))
                    }
                }
            } catch {
                // iOS stopped the updates; the next share starts them again.
            }
        }
    }

    /// One fresh position to share a map from, or nil when iOS gives none worth sharing
    /// within `seconds`.
    func current(within seconds: Double = 15) async -> LocationFix? {
        guard isAllowedToFollow else {
            return nil
        }
        return await withTaskGroup(of: LocationFix?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if let location = update.location, location.horizontalAccuracy > 0, location.horizontalAccuracy <= Self.widestAccuracyMetres {
                            return Self.fix(location)
                        }
                    }
                } catch {
                    return nil
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private nonisolated static func fix(_ location: CLLocation) -> LocationFix {
        LocationFix(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy,
            at: location.timestamp
        )
    }
}
