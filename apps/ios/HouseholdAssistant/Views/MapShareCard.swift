// A map a person shared, in their own bubble: the map round where they are with their face
// pinned there and a halo under it while it is live, then what it is: Location, Live
// location with how long it has left, or that sharing ended or stopped. While this phone's
// own live map runs, Stop ends it at once.
//
// The footer sits on the bubble's own colour, royal for this phone's person as their
// bubble always is, so the map needs no colour of its own.

import MapKit
import SwiftUI

struct MapShareCard: View {
    let message: RoomMessage
    let location: SharedLocation
    let isOwn: Bool
    let foreground: Color

    @Environment(AppModel.self) private var model
    @State private var isStopping = false

    /// Wide enough to place a street, and wider for a neighbourhood shared approximately.
    private var region: MKCoordinateRegion {
        let position = message.shownPosition ?? location.position
        let place = MapPoint(latitude: Double(position.latitudeE6) / 1_000_000, longitude: Double(position.longitudeE6) / 1_000_000)
        return MKCoordinateRegion(around: place, metres: max(900, Double(position.accuracy) * 4))
    }

    private var isStopped: Bool {
        message.live != nil && message.live?.position == nil
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let isLive = !isStopped && (location.endsAt.map { context.date < $0 } ?? false)
            VStack(alignment: .leading, spacing: 0) {
                MapSnapshot(region: region, height: 140) { projection in
                    if let position = message.shownPosition {
                        let point = projection.point(MapPoint(
                            latitude: Double(position.latitudeE6) / 1_000_000,
                            longitude: Double(position.longitudeE6) / 1_000_000
                        ))
                        ZStack {
                            if isLive {
                                MapPulse(size: 34)
                            }
                            ParticipantAvatar(participant: model.room.participant(message.author), size: 30)
                                .padding(3)
                                .background(.white, in: Circle())
                                .shadow(color: Palette.navy.opacity(0.25), radius: 4, y: 2)
                        }
                        .position(point)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                footer(isLive: isLive, now: context.date)
            }
            .frame(width: 250)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityWords(isLive: isLive, now: context.date))
        }
    }

    private func footer(isLive: Bool, now: Date) -> some View {
        HStack(spacing: 8) {
            if isLive {
                Circle()
                    .fill(foreground)
                    .frame(width: 8, height: 8)
                    .shadow(color: foreground.opacity(0.5), radius: 3)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: location.isLive ? "location.slash.fill" : "location.fill")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            Text(title(isLive: isLive))
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 4)
            if isLive && isOwn {
                Button {
                    isStopping = true
                    Task {
                        await model.stopMapShare(message.id)
                        isStopping = false
                    }
                } label: {
                    Text("Stop")
                        .font(.footnote.weight(.bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .overlay {
                            Capsule()
                                .strokeBorder(foreground.opacity(0.7), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .disabled(isStopping)
                .accessibilityHint("Stops sharing where you are in this chat")
            }
            Text(detail(isLive: isLive, now: now))
                .font(.caption)
                .monospacedDigit()
                .opacity(0.85)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func title(isLive: Bool) -> String {
        if isLive {
            return "Live location"
        }
        if location.isLive {
            return isStopped ? "Stopped sharing" : "Sharing ended"
        }
        return "Location"
    }

    /// How long a live map has left, as "Live for 45 min" or "Until 11:59 PM", or when an
    /// ended one or a map shared once was sent.
    private func detail(isLive: Bool, now: Date) -> String {
        guard isLive, let endsAt = location.endsAt else {
            return message.sentAt.formatted(date: .omitted, time: .shortened)
        }
        let minutes = Int((endsAt.timeIntervalSince(now) / 60).rounded(.up))
        return minutes < 60 ? "Live for \(minutes) min" : "Until " + endsAt.formatted(date: .omitted, time: .shortened)
    }

    private func accessibilityWords(isLive: Bool, now: Date) -> String {
        let name = model.room.participant(message.author)?.name
        let who = isOwn ? "Your location" : name.map { "\($0)'s location" } ?? "Location"
        return isLive ? "\(who), live, \(detail(isLive: true, now: now))" : "\(who), \(title(isLive: false))"
    }
}
