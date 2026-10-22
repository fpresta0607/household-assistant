// A month in photos, from the photos the owner lets Steward AI read: its best shots, spread
// over the days it has photos of, for the recap's grid and its short video, and what the line
// about it is made from: how many photos, over how many days, and what they mostly show.
// Everything is read and chosen on this phone (PhotoKeeperScanner); nothing leaves it.

import Foundation

struct MonthlyRecap: Equatable, Sendable {
    /// How many shots a recap shows and its video plays.
    static let shots = 12
    /// Fewer good photos than this make no recap.
    static let fewest = 3
    /// Labels too general to say what a month was about.
    static let generalScenes: Set<String> = ["outdoor", "indoor", "structure", "sky", "people", "adult", "material", "textile", "wood_processed", "document", "screenshot", "printed_page"]

    /// "October 2026".
    let title: String
    /// The chosen shots, in the order taken.
    let best: [PhotoFacts]
    let photoCount: Int
    let dayCount: Int
    /// What the month's photos mostly show, most first, at most three.
    let scenes: [String]

    /// The recap of the month that starts at `start` in `calendar`, from `photos` (any others
    /// are left out), or nil when it has too few good photos. Screenshots, utility shots and
    /// blurry ones never make it, and a shot taken several times shows once, at its best.
    static func make(from photos: [PhotoFacts], monthStarting start: Date, calendar: Calendar) -> MonthlyRecap? {
        guard let month = calendar.dateInterval(of: .month, for: start) else {
            return nil
        }
        let inMonth = photos.filter { month.start <= $0.takenAt && $0.takenAt < month.end }
        let good = inMonth.filter { !$0.isScreenshot && !$0.isUtility && !CleanOutBatch.isBlurry($0) }
        let lesser = Set(NearDuplicates.groups(in: good).flatMap { group in
            group.filter { $0.id != NearDuplicates.best(of: group)?.id }.map(\.id)
        })
        let candidates = good.filter { !lesser.contains($0.id) }
        guard candidates.count >= fewest else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "LLLL yyyy"
        let days = Dictionary(grouping: inMonth) { calendar.startOfDay(for: $0.takenAt) }
        return MonthlyRecap(
            title: formatter.string(from: month.start),
            best: spread(candidates, calendar: calendar).sorted { $0.takenAt < $1.takenAt },
            photoCount: inMonth.count,
            dayCount: days.count,
            scenes: mostShown(in: inMonth)
        )
    }

    /// The best `shots` of `candidates`, a day at a time: each round takes the best photo left
    /// of every day, the days whose best is better first, so one busy day never fills the recap.
    private static func spread(_ candidates: [PhotoFacts], calendar: Calendar) -> [PhotoFacts] {
        var byDay = Dictionary(grouping: candidates) { calendar.startOfDay(for: $0.takenAt) }
            .mapValues { $0.sorted { NearDuplicates.rank($0) > NearDuplicates.rank($1) } }
        var chosen: [PhotoFacts] = []
        while chosen.count < shots, !byDay.isEmpty {
            let round = byDay.compactMap { day, photos in photos.first.map { (day, $0) } }
                .sorted { NearDuplicates.rank($0.1) > NearDuplicates.rank($1.1) }
            for (day, photo) in round where chosen.count < shots {
                chosen.append(photo)
                byDay[day]?.removeFirst()
                if byDay[day]?.isEmpty == true {
                    byDay[day] = nil
                }
            }
        }
        return chosen
    }

    private static func mostShown(in photos: [PhotoFacts]) -> [String] {
        var counts: [String: Int] = [:]
        for photo in photos {
            for scene in Set(photo.scenes) where !generalScenes.contains(scene) {
                counts[scene, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(3).map(\.key)
    }
}
