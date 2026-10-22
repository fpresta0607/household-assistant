// What iOS measured of the app on this iPhone, handed over by MetricKit at most once a day:
// how much scrolling hitched and how the app hung, reduced to PhoneMetrics for the owner's
// own gateway log (CFO decision 1007134).

import Foundation
import MetricKit

@MainActor
final class MetricsReporter: NSObject, MXMetricManagerSubscriber {
    /// Each delivery's days, on the main actor.
    var onReport: (([PhoneMetrics]) -> Void)?

    /// From launch on. iOS keeps what it gathered until a subscriber is there to take it.
    func start() {
        MXMetricManager.shared.add(self)
    }

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        let reports = payloads.map(Self.metrics)
        Task { @MainActor in
            self.onReport?(reports)
        }
    }

    private nonisolated static func metrics(_ payload: MXMetricPayload) -> PhoneMetrics {
        let buckets = payload.applicationResponsivenessMetrics?.histogrammedApplicationHangTime.bucketEnumerator.allObjects ?? []
        let hangs = buckets.compactMap { $0 as? MXHistogramBucket<UnitDuration> }.map { bucket in
            PhoneMetrics.HangBucket(
                start: bucket.bucketStart.converted(to: .seconds).value,
                end: bucket.bucketEnd.converted(to: .seconds).value,
                count: bucket.bucketCount
            )
        }
        return PhoneMetrics(
            from: payload.timeStampBegin,
            to: payload.timeStampEnd,
            appVersion: payload.latestApplicationVersion,
            build: payload.metaData?.applicationBuildVersion
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            // MetricKit gives it in milliseconds of hitching per second of scrolling.
            scrollHitchMsPerSecond: payload.animationMetrics?.scrollHitchTimeRatio.value,
            hangs: hangs
        )
    }
}
