// What iOS measured of the app over a day, reduced to the figures the owner's gateway logs:
// the hang histogram to a count and a time, and the parameters
// deploy/openclaw/plugins/household-app/phone-metrics.js takes.

import XCTest
@testable import HouseholdAssistant

final class PhoneMetricsTests: XCTestCase {
    /// Midnight to midnight UTC, 16 to 17 October 2026.
    private static let from = Date(timeIntervalSince1970: 1_792_108_800)
    private static let to = Date(timeIntervalSince1970: 1_792_195_200)

    private func day(scrollHitchMsPerSecond: Double? = 4.25, hangs: [PhoneMetrics.HangBucket]) -> PhoneMetrics {
        PhoneMetrics(from: Self.from, to: Self.to, appVersion: "1.0", build: "14", scrollHitchMsPerSecond: scrollHitchMsPerSecond, hangs: hangs)
    }

    func testHangsAreCountedAndTimedAtTheMiddleOfTheirBar() {
        // Arrange
        let hangs = [
            PhoneMetrics.HangBucket(start: 0.25, end: 0.75, count: 4),
            PhoneMetrics.HangBucket(start: 1, end: 2, count: 2),
            PhoneMetrics.HangBucket(start: 2, end: 4, count: 0),
        ]

        // Act
        let metrics = day(hangs: hangs)

        // Assert
        XCTAssertEqual(metrics.hangCount, 6)
        XCTAssertEqual(metrics.hangSeconds, 5, accuracy: 0.000_001)
    }

    func testADayWithNoHangsIsNone() {
        // Act
        let metrics = day(hangs: [])

        // Assert
        XCTAssertEqual(metrics.hangCount, 0)
        XCTAssertEqual(metrics.hangSeconds, 0)
    }

    func testTheReportIsFiguresAndTheBuildInMilliseconds() {
        // Act
        let params = day(hangs: [PhoneMetrics.HangBucket(start: 1, end: 2, count: 2)]).params

        // Assert
        XCTAssertEqual(params, .object([
            "from": .number(1_792_108_800_000),
            "to": .number(1_792_195_200_000),
            "appVersion": .string("1.0"),
            "build": .string("14"),
            "scrollHitchMsPerSecond": .number(4.25),
            "hangCount": .number(2),
            "hangSeconds": .number(3),
        ]))
    }

    func testADayWithNoScrollingSendsNoHitchRatio() {
        // Act
        let params = day(scrollHitchMsPerSecond: nil, hangs: []).params

        // Assert
        XCTAssertEqual(params["scrollHitchMsPerSecond"], .null)
    }
}
