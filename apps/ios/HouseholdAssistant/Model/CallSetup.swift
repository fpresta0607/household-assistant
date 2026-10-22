// How a call with the assistant came up, sent with the call's end, so the owner's gateway
// logs how long this phone's calls take to connect: from the tap to the gateway's link, to
// the sound iOS handed over, and to connected, then from the first words sent to the first
// words of the reply, and whether CallKit took the call. Numbers and the route only, never
// anything said. The gateway's deploy/openclaw/plugins/household-app/call-log.js writes
// the line. Plain values, so it is tested on Linux.

import Foundation

struct CallSetup: Equatable, Sendable {
    let build: String
    /// Milliseconds from the tap to each moment, nil for one the call never reached.
    let linkMs: Int?
    let soundMs: Int?
    let connectedMs: Int?
    /// Milliseconds from the call's first words sent to the first words of the reply.
    let firstReplyMs: Int?
    /// "callkit", "app" with why the app ran it itself, or "unplaced" for a call that ended
    /// before it was placed.
    let route: String

    init(
        build: String,
        tappedAt: Date,
        state: CallState,
        placement: CallPlacement,
        firstSentAt: Date?,
        firstReplyAt: Date?
    ) {
        self.build = build
        linkMs = Self.milliseconds(from: tappedAt, to: state.linkUpAt)
        soundMs = Self.milliseconds(from: tappedAt, to: state.soundAt)
        connectedMs = Self.milliseconds(from: tappedAt, to: state.connectedAt)
        firstReplyMs = firstSentAt.flatMap { Self.milliseconds(from: $0, to: firstReplyAt) }
        switch placement.route {
        case .callKit:
            route = "callkit"
        case .app(let reason):
            route = "app \(reason)"
        case nil:
            route = "unplaced"
        }
    }

    /// The `setup` household-app.call.end takes beside the call.
    var params: JSONValue {
        var members: [String: JSONValue] = ["build": .string(build), "route": .string(route)]
        members["linkMs"] = linkMs.map { JSONValue.number(Double($0)) }
        members["soundMs"] = soundMs.map { JSONValue.number(Double($0)) }
        members["connectedMs"] = connectedMs.map { JSONValue.number(Double($0)) }
        members["firstReplyMs"] = firstReplyMs.map { JSONValue.number(Double($0)) }
        return .object(members)
    }

    /// A link already up at the tap counts from the tap, so no figure is ever below zero.
    private static func milliseconds(from start: Date, to moment: Date?) -> Int? {
        moment.map { max(0, Int(($0.timeIntervalSince(start) * 1000).rounded())) }
    }
}
