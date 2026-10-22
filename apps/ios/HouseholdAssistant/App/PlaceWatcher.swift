// iOS watching the places of this phone's reminders by place, with a circle round each
// (CLMonitor), even with the app closed: iOS starts the app in the background to say a
// circle was crossed, and opening the same monitor again is what hands that over. So the
// monitor is opened as the app starts, whatever it starts for, whenever there is a place
// to watch. With none, it stays closed: nothing could have been crossed.
//
// The places stay on this phone. What happens on a crossing is PlaceReminders' to decide.

import CoreLocation
import Foundation

@MainActor
final class PlaceWatcher {
    /// iOS learned which side of a watched place's edge the person is on: the watch's id,
    /// and whether they are inside.
    var onSeen: ((String, Bool) -> Void)?

    /// Off in the screenshot tests and the demo, which have no places to watch.
    private let isAllowedToWatch: Bool
    private var monitor: CLMonitor?
    private var listening: Task<Void, Never>?

    init(isAllowedToWatch: Bool) {
        self.isAllowedToWatch = isAllowedToWatch
    }

    /// Opens the monitor and hears every crossing iOS reports, those that woke the app first.
    func start() async {
        guard isAllowedToWatch, monitor == nil else {
            return
        }
        let monitor = await CLMonitor(PlaceWatch.monitorName)
        self.monitor = monitor
        listening = Task { [weak self] in
            do {
                for try await event in await monitor.events {
                    switch event.state {
                    case .satisfied:
                        self?.onSeen?(event.identifier, true)
                    case .unsatisfied:
                        self?.onSeen?(event.identifier, false)
                    default:
                        break
                    }
                }
            } catch {
                // The monitor stopped; the next launch opens it again.
            }
        }
    }

    /// Watches exactly these places: each one not watched yet is added, and each one no
    /// longer wanted is dropped.
    func watch(_ watches: [PlaceWatch]) async {
        // With nothing to watch and the monitor never opened, there is nothing to drop
        // either, so it stays closed: a launch with no reminders by place opens no monitor.
        guard isAllowedToWatch, !watches.isEmpty || monitor != nil else {
            return
        }
        await start()
        guard let monitor else {
            return
        }
        let wanted = Set(watches.map(\.id))
        let known = Set(await monitor.identifiers)
        for id in known.subtracting(wanted) {
            await monitor.remove(id)
        }
        for watch in watches where !known.contains(watch.id) {
            let circle = CLMonitor.CircularGeographicCondition(
                center: CLLocationCoordinate2D(latitude: watch.center.latitude, longitude: watch.center.longitude),
                radius: watch.radius
            )
            await monitor.add(circle, identifier: watch.id)
        }
    }
}
