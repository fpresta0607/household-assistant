// The photo keeper's choices, from made-up photo facts: which shots a month's recap shows and
// the line under it, what the camera roll clean-out offers, and that nothing is deleted
// without the owner's tap on the batch, and then only what stays ticked.

import XCTest
@testable import HouseholdAssistant

final class PhotoKeeperTests: XCTestCase {
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 1 October 2026, midnight UTC.
    private static let october = Date(timeIntervalSince1970: 1_790_812_800)

    private static func photo(
        _ id: String,
        day: Int,
        minute: Int = 0,
        score: Double = 0.5,
        sharpness: Double = 400,
        print: [Float] = [1, 0, 0],
        isScreenshot: Bool = false,
        isFavorite: Bool = false,
        isUtility: Bool = false,
        scenes: [String] = []
    ) -> PhotoFacts {
        PhotoFacts(
            id: id,
            takenAt: october.addingTimeInterval(Double(day - 1) * 86_400 + Double(minute) * 60),
            isScreenshot: isScreenshot,
            isFavorite: isFavorite,
            sharpness: sharpness,
            score: score,
            isUtility: isUtility,
            scenes: scenes,
            print: print
        )
    }

    // MARK: The recap

    func testRecapShowsOneShotOfABurstSpreadOverTheDaysAndLeavesOutScreenshotsAndBlur() throws {
        // Arrange: a burst of three on the 3rd, one good photo on each of two other days, a
        // screenshot, a receipt and a blurry shot.
        let photos = [
            Self.photo("burst-1", day: 3, score: 0.2, print: [1, 0, 0]),
            Self.photo("burst-2", day: 3, minute: 1, score: 0.9, print: [1, 0.1, 0]),
            Self.photo("burst-3", day: 3, minute: 1, score: 0.4, print: [1, 0, 0.1]),
            Self.photo("lake", day: 10, score: 0.7, print: [0, 1, 0], scenes: ["lake", "outdoor"]),
            Self.photo("cake", day: 20, score: 0.6, print: [0, 0, 1], scenes: ["cake"]),
            Self.photo("screenshot", day: 20, isScreenshot: true),
            Self.photo("receipt", day: 21, isUtility: true),
            Self.photo("blur", day: 22, score: -0.4, sharpness: 12),
        ]

        // Act
        let recap = try XCTUnwrap(MonthlyRecap.make(from: photos, monthStarting: Self.october, calendar: Self.utc))

        // Assert
        XCTAssertEqual(recap.title, "October 2026")
        XCTAssertEqual(recap.best.map(\.id), ["burst-2", "lake", "cake"])
        XCTAssertEqual(recap.photoCount, 8)
        XCTAssertEqual(recap.dayCount, 5)
        XCTAssertEqual(recap.scenes, ["cake", "lake"], "a label as general as outdoor says nothing")
    }

    func testOneBusyDayNeverFillsTheRecap() throws {
        // Arrange: twenty photos on the 5th, each a different scene and better than the one
        // photo on the 6th.
        var photos = (0..<20).map { index in
            Self.photo("busy-\(index)", day: 5, minute: index * 10, score: 0.9, print: [Float(index), 5, 5])
        }
        photos.append(Self.photo("quiet", day: 6, score: 0.1, print: [9, 9, 9]))

        // Act
        let recap = try XCTUnwrap(MonthlyRecap.make(from: photos, monthStarting: Self.october, calendar: Self.utc))

        // Assert
        XCTAssertEqual(recap.best.count, MonthlyRecap.shots)
        XCTAssertTrue(recap.best.contains { $0.id == "quiet" })
    }

    func testAMonthWithTooFewGoodPhotosMakesNoRecap() {
        let photos = [Self.photo("one", day: 2), Self.photo("two", day: 3, print: [0, 1, 0]), Self.photo("next-month", day: 40, print: [0, 0, 1])]
        XCTAssertNil(MonthlyRecap.make(from: photos, monthStarting: Self.october, calendar: Self.utc))
    }

    func testThePlainLineSaysHowManyPhotosOverHowManyDaysAndWhatTheyShow() throws {
        let photos = [
            Self.photo("a", day: 1, print: [1, 0, 0], scenes: ["cat"]),
            Self.photo("b", day: 2, print: [0, 1, 0], scenes: ["cat", "beach"]),
            Self.photo("c", day: 2, minute: 300, print: [0, 0, 1], scenes: ["food"]),
        ]
        let recap = try XCTUnwrap(MonthlyRecap.make(from: photos, monthStarting: Self.october, calendar: Self.utc))
        XCTAssertEqual(RecapLine.plain(for: recap), "October 2026: 3 photos over 2 days, mostly cat, beach and food.")
        XCTAssertTrue(RecapLine.prompt(for: recap).contains("3 photos over 2 days, mostly of cat, beach and food"))
    }

    func testAModelLineThatRamblesOrRunsOverALineIsNotShown() {
        XCTAssertEqual(RecapLine.cleaned("  \"A month of lake days and birthday cake.\"\n"), "A month of lake days and birthday cake.")
        XCTAssertNil(RecapLine.cleaned(""))
        XCTAssertNil(RecapLine.cleaned("First line.\nSecond line."))
        XCTAssertNil(RecapLine.cleaned(String(repeating: "word ", count: 60)))
    }

    // MARK: The clean-out

    func testTheCleanOutOffersABurstPastItsFavoriteBlurAndOldScreenshotsButNeverAFavorite() {
        // Arrange
        let now = Self.october.addingTimeInterval(45 * 86_400)
        let photos = [
            Self.photo("burst-1", day: 3, score: 0.2, print: [1, 0, 0]),
            Self.photo("burst-2", day: 3, minute: 1, score: 0.9, print: [1, 0.1, 0]),
            Self.photo("burst-3", day: 3, minute: 1, score: 0.1, print: [1, 0, 0.1], isFavorite: true),
            Self.photo("blur", day: 4, score: -0.3, sharpness: 8, print: [0, 1, 0]),
            Self.photo("soft-portrait", day: 4, minute: 30, score: 0.6, sharpness: 8, print: [0, 0, 1]),
            Self.photo("old-screenshot", day: 5, isScreenshot: true),
            Self.photo("new-screenshot", day: 40, isScreenshot: true),
            Self.photo("blurry-favorite", day: 6, score: -0.5, sharpness: 5, print: [5, 5, 5], isFavorite: true),
        ]

        // Act
        let batch = CleanOutBatch.propose(from: photos, now: now)

        // Assert
        XCTAssertEqual(batch.items, [
            CleanOutItem(id: "burst-2", reason: .duplicate, keptInstead: "burst-3"),
            CleanOutItem(id: "burst-1", reason: .duplicate, keptInstead: "burst-3"),
            CleanOutItem(id: "blur", reason: .blurry, keptInstead: nil),
            CleanOutItem(id: "old-screenshot", reason: .oldScreenshot, keptInstead: nil),
        ])
    }

    func testTwoLookalikeShotsHoursApartAreNotDuplicates() {
        let photos = [Self.photo("morning", day: 8, print: [1, 0, 0]), Self.photo("evening", day: 8, minute: 600, print: [1, 0, 0])]
        XCTAssertTrue(NearDuplicates.groups(in: photos).isEmpty)
    }

    func testAFlatGreyThumbnailIsBlurryAndACheckerboardIsSharp() {
        let flat = [UInt8](repeating: 128, count: 64 * 64)
        let checkerboard = (0..<(64 * 64)).map { index in UInt8((index / 64 + index % 64) % 2 == 0 ? 0 : 255) }
        XCTAssertEqual(Sharpness.variance(of: flat, width: 64, height: 64), 0)
        XCTAssertGreaterThan(Sharpness.variance(of: checkerboard, width: 64, height: 64), Sharpness.blurry)
        XCTAssertEqual(Sharpness.variance(of: [1, 2], width: 2, height: 1), 0)
    }

    // MARK: Nothing deleted without the tap

    private actor RecordingDeleter: PhotoDeleting {
        private(set) var calls: [[String]] = []

        func delete(_ ids: [String]) async throws {
            calls.append(ids)
        }
    }

    func testReviewingAndUntickingDeleteNothingAndTheTapDeletesOnlyWhatStaysTicked() async throws {
        // Arrange
        let batch = CleanOutBatch(items: [
            CleanOutItem(id: "burst-1", reason: .duplicate, keptInstead: "burst-2"),
            CleanOutItem(id: "blur", reason: .blurry, keptInstead: nil),
            CleanOutItem(id: "old-screenshot", reason: .oldScreenshot, keptInstead: nil),
        ])
        let deleter = RecordingDeleter()
        var review = CleanOutReview(batch: batch)

        // Act: the owner unticks the blurry one and looks again.
        review.toggle("blur")
        review.toggle("old-screenshot")
        review.toggle("old-screenshot")
        let beforeTap = await deleter.calls
        let deleted = try await review.delete(using: deleter)

        // Assert
        XCTAssertEqual(beforeTap, [], "nothing is deleted before the tap")
        XCTAssertEqual(deleted, 2)
        let calls = await deleter.calls
        XCTAssertEqual(calls, [["burst-1", "old-screenshot"]])
        XCTAssertFalse(review.isChosen("blur"))
        XCTAssertFalse(review.isChosen("not-in-the-batch"))
    }

    func testATapWithNothingTickedDeletesNothing() async throws {
        let deleter = RecordingDeleter()
        var review = CleanOutReview(batch: CleanOutBatch(items: [CleanOutItem(id: "blur", reason: .blurry, keptInstead: nil)]))
        review.choose(.blurry, isChosen: false)
        let deleted = try await review.delete(using: deleter)
        XCTAssertEqual(deleted, 0)
        let calls = await deleter.calls
        XCTAssertEqual(calls, [])
    }
}
