// What iOS measured of the app on this iPhone over about a day, as MetricKit hands it to the
// app once a day, reduced to the few figures the owner's gateway logs: how much scrolling
// hitched, and how often and how long the app hung (CFO decision 1007134). Numbers only,
// never anything anybody said. Plain values, so the reduction is tested on Linux. The
// MetricKit side is App/MetricsReporter.swift, and the gateway's
// deploy/openclaw/plugins/household-app/phone-metrics.js writes the line.

import Foundation

struct PhoneMetrics: Equatable, Sendable {
    /// One bar of MetricKit's hang histogram: hangs that lasted from `start` to `end`
    /// seconds, `count` of them.
    struct HangBucket: Equatable, Sendable {
        let start: Double
        let end: Double
        let count: Int
    }

    let from: Date
    let to: Date
    let appVersion: String
    let build: String
    /// Milliseconds of hitching in each second of scrolling; nil on a day with none.
    let scrollHitchMsPerSecond: Double?
    let hangCount: Int
    /// How long the app hung in all, each hang counted at its bar's middle.
    let hangSeconds: Double

    init(from: Date, to: Date, appVersion: String, build: String, scrollHitchMsPerSecond: Double?, hangs: [HangBucket]) {
        self.from = from
        self.to = to
        self.appVersion = appVersion
        self.build = build
        self.scrollHitchMsPerSecond = scrollHitchMsPerSecond
        hangCount = hangs.reduce(0) { $0 + $1.count }
        hangSeconds = hangs.reduce(0) { $0 + Double($1.count) * ($1.start + $1.end) / 2 }
    }

    /// The parameters household-app.metrics.report takes.
    var params: JSONValue {
        var members: [String: JSONValue] = [
            "from": .number((from.timeIntervalSince1970 * 1000).rounded()),
            "to": .number((to.timeIntervalSince1970 * 1000).rounded()),
            "appVersion": .string(appVersion),
            "build": .string(build),
            "hangCount": .number(Double(hangCount)),
            "hangSeconds": .number(hangSeconds),
        ]
        members["scrollHitchMsPerSecond"] = scrollHitchMsPerSecond.map(JSONValue.number) ?? .null
        return .object(members)
    }
}
