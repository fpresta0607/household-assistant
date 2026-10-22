// An assistant's small map in an answer: the place it named with a gold pin, and when it
// asked, the way there from where this phone is, worked out by Apple Maps on the phone,
// with when they would arrive and the road it takes. The way is a royal line and the
// phone's own place a royal dot with a still halo, both marks on the map, never fills.

import MapKit
import SwiftUI

struct MapCardView: View {
    let card: MapCard
    /// Nil until the gateway has kept the message, and the way is worked out only then.
    let messageId: String?

    @Environment(AppModel.self) private var model

    private var route: MapRoute? {
        messageId.flatMap { model.mapRoutes.routes[card.routeKey(in: $0)] }
    }

    private var failure: String? {
        messageId.flatMap { model.mapRoutes.failures[card.routeKey(in: $0)] }
    }

    var body: some View {
        let route = route
        VStack(alignment: .leading, spacing: 8) {
            MapSnapshot(region: region(with: route), height: 124) { projection in
                if let route, let start = route.points.first {
                    Path { path in
                        path.addLines(route.points.map { projection.point($0) })
                    }
                    .stroke(Palette.highlight.opacity(0.85), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    ZStack {
                        MapPulse(size: 22)
                        Circle()
                            .fill(Palette.highlight)
                            .frame(width: 13, height: 13)
                            .overlay {
                                Circle()
                                    .strokeBorder(.white, lineWidth: 2.5)
                            }
                    }
                    .position(projection.point(start))
                }
                PlacePin(label: card.label)
                    .position(projection.point(card.center))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            if let route {
                HStack(spacing: 8) {
                    chip("Arrive " + route.arrival(leaving: Date()).formatted(date: .omitted, time: .shortened))
                    if !route.name.isEmpty {
                        chip("Via " + route.name)
                    }
                }
            } else if let label = card.label {
                Label(label, systemImage: "mappin.and.ellipse")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CardStyle.ink)
            }
            if card.route != nil, route == nil, let note = failure ?? waitingNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(CardStyle.secondaryInk)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardPanel()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityWords(route))
        .task(id: messageId) {
            guard let messageId, model.permissions.status(of: .location) == .allowed else {
                return
            }
            await model.mapRoutes.route(for: card, in: messageId)
        }
    }

    /// Why the way is not there yet, when the phone is not allowed to know where it is.
    private var waitingNote: String? {
        model.permissions.status(of: .location) == .allowed ? nil : "The way there needs Location for Steward AI."
    }

    private func region(with route: MapRoute?) -> MKCoordinateRegion {
        guard let route else {
            return MKCoordinateRegion(around: card.center, metres: 1500)
        }
        return MKCoordinateRegion(holding: route.points + [card.center], atLeast: 1500)
    }

    /// A small white chip with the words in the accent and an accent rim.
    private func chip(_ words: String) -> some View {
        Text(words)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(CardStyle.accent)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.white, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(CardStyle.accent.opacity(0.35), lineWidth: 1)
            }
    }

    private func accessibilityWords(_ route: MapRoute?) -> String {
        let place = card.label ?? "A place"
        guard let route else {
            return "Map of \(place)"
        }
        return "Map of the way to \(place), \(route.minutes) minutes" + (route.name.isEmpty ? "" : ", via \(route.name)")
    }
}
