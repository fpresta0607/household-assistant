// The ways there the map cards on screen have asked for, worked out once each and kept
// while the app runs. Apple Maps works each out on the phone from where it is; the
// gateway never sees one.

import Foundation
import Observation

@MainActor
@Observable
final class MapRoutes {
    /// By `MapCard.routeKey(in:)`.
    private(set) var routes: [String: MapRoute] = [:]
    /// Why a way could not be found, by the same key, in words a person can read.
    private(set) var failures: [String: String] = [:]

    @ObservationIgnored private let find: (MapCard) async throws -> MapRoute
    @ObservationIgnored private var finding: Set<String> = []

    init(find: @escaping (MapCard) async throws -> MapRoute) {
        self.find = find
    }

    /// Works out the way for a card in `messageId`, unless it is known, being found, or
    /// could not be found.
    func route(for card: MapCard, in messageId: String) async {
        let key = card.routeKey(in: messageId)
        guard card.route != nil, routes[key] == nil, failures[key] == nil, !finding.contains(key) else {
            return
        }
        finding.insert(key)
        defer {
            finding.remove(key)
        }
        do {
            routes[key] = try await find(card)
        } catch {
            failures[key] = ErrorText.describe(error)
        }
    }

    /// A way already known, as the demo and the screenshots give it.
    func keep(_ route: MapRoute, for key: String) {
        routes[key] = route
    }

    func reset() {
        routes = [:]
        failures = [:]
    }
}
