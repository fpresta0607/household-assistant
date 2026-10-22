// The photo keeper behind Settings, Photos: last month's recap from the photos the person lets
// Steward AI read, its short video, and the camera roll clean-out they review. Every scan is
// a utility-priority task off the main thread (PhotoKeeperScanner), one at a time, and
// stops when the page goes. Nothing is deleted but through the review's own tap
// (CleanOutReview.delete), and iOS asks once more and keeps the photos 30 days in Recently
// Deleted. Nothing here leaves the phone.

import Foundation
import Observation
import Photos
import UserNotifications

@MainActor
@Observable
final class PhotoKeeperModel {
    /// Which scan runs: last month's for the recap, or the library's for the clean-out.
    enum Scan {
        case recap
        case cleanOut
    }

    /// The monthly reminder that a recap is ready, on the 1st at 10 in the morning.
    static let monthlyNotice = "photo-recap-monthly"

    private(set) var access: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var recap: MonthlyRecap?
    private(set) var recapLine: String?
    /// The scan in progress, and how far it has come, from 0 to 1.
    private(set) var scan: Scan?
    private(set) var progress: Double = 0
    /// Whether last month's recap was looked for and none could be made.
    private(set) var isRecapEmpty = false
    private(set) var movie: URL?
    private(set) var isMakingMovie = false
    var review: CleanOutReview?
    /// What the last step came to, in a sentence, such as how many photos went.
    private(set) var notice: String?

    @ObservationIgnored private let scanner = PhotoKeeperScanner()
    @ObservationIgnored private var work: Task<Void, Never>?

    var canRead: Bool {
        access == .authorized || access == .limited
    }

    /// Asks iOS to let Steward AI read the library, where it has not asked yet, and once it
    /// may, sets the monthly reminder.
    func askForAccess() async {
        access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        if canRead {
            await Self.setMonthlyNotice()
        }
    }

    /// Last month's recap, read afresh.
    func makeRecap(now: Date = Date(), calendar: Calendar = .current) {
        guard canRead, let thisMonth = calendar.dateInterval(of: .month, for: now),
              let lastMonth = calendar.dateInterval(of: .month, for: thisMonth.start.addingTimeInterval(-1)) else {
            return
        }
        run(.recap) { model, scanner in
            let facts = await scanner.facts(in: lastMonth) { done, total in
                Task { @MainActor in
                    model.progress = Double(done) / Double(max(total, 1))
                }
            }
            guard !Task.isCancelled else {
                return
            }
            let recap = MonthlyRecap.make(from: facts, monthStarting: lastMonth.start, calendar: calendar)
            var line: String?
            if let recap {
                line = await RecapWriter.line(for: recap)
            }
            model.recap = recap
            model.recapLine = line
            model.isRecapEmpty = recap == nil
            model.movie = nil
        }
    }

    /// The recap's short video, drawn on this phone.
    func makeMovie() {
        guard let recap, !isMakingMovie else {
            return
        }
        isMakingMovie = true
        Task(priority: .utility) { [weak self] in
            let movie = try? await RecapMovieMaker.make(recap)
            await MainActor.run {
                self?.movie = movie
                self?.isMakingMovie = false
                if movie == nil {
                    self?.notice = "The video could not be made."
                }
            }
        }
    }

    /// The clean-out batch from the newest photos of the library, for the person to review.
    func findCleanOut(now: Date = Date()) {
        guard canRead else {
            return
        }
        run(.cleanOut) { model, scanner in
            let facts = await scanner.facts(in: DateInterval(start: .distantPast, end: now)) { done, total in
                Task { @MainActor in
                    model.progress = Double(done) / Double(max(total, 1))
                }
            }
            guard !Task.isCancelled else {
                return
            }
            let batch = CleanOutBatch.propose(from: facts, now: now)
            model.review = batch.items.isEmpty ? nil : CleanOutReview(batch: batch)
            model.notice = batch.items.isEmpty ? "Nothing to clear: no near-duplicates, blurry shots or old screenshots." : nil
        }
    }

    /// The person's tap on Delete: the ticked photos go to iOS, which asks once more.
    func deleteChosen() async {
        guard let review else {
            return
        }
        do {
            let count = try await review.delete(using: PhotoLibraryDeleter())
            self.review = nil
            notice = count == 0 ? nil : "\(count == 1 ? "1 photo" : "\(count) photos") moved to Recently Deleted, where iOS keeps them for 30 days."
        } catch {
            // iOS's own question answered Don't Allow, or the library refused: nothing went.
            notice = "Nothing was deleted."
        }
    }

    /// Stops a scan, as the page goes.
    func stop() {
        work?.cancel()
        work = nil
        scan = nil
    }

    /// One scan at a time, at utility priority, its progress cleared when it ends.
    private func run(_ kind: Scan, _ body: @escaping @MainActor (PhotoKeeperModel, PhotoKeeperScanner) async -> Void) {
        work?.cancel()
        notice = nil
        progress = 0
        scan = kind
        let scanner = scanner
        work = Task(priority: .utility) { [weak self] in
            guard let self else {
                return
            }
            await body(self, scanner)
            if !Task.isCancelled {
                self.scan = nil
            }
        }
    }

    private static func setMonthlyNotice() async {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Your photo recap"
        content.body = "Last month's best shots and a short video are ready in Steward AI, Settings, Photos."
        var day = DateComponents()
        day.day = 1
        day.hour = 10
        let request = UNNotificationRequest(identifier: monthlyNotice, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: day, repeats: true))
        try? await center.add(request)
    }
}
