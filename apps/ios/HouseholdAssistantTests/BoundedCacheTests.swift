// The cache a message's readings are kept in: each key worked out once and then read,
// never more entries than it holds, and the one used longest ago the first to go.

import XCTest
@testable import HouseholdAssistant

final class BoundedCacheTests: XCTestCase {
    func testAKeyIsWorkedOutOnceAndThenRead() {
        let cache = BoundedCache<String, Int>(capacity: 4)
        var made = 0

        let first = cache.value(for: "a") {
            made += 1
            return 1
        }
        let second = cache.value(for: "a") {
            made += 1
            return 2
        }

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 1, "the kept value, not a new one")
        XCTAssertEqual(made, 1)
    }

    func testAKeyNeverKeptReadsAsNothing() {
        let cache = BoundedCache<String, Int>(capacity: 4)

        XCTAssertNil(cache.value(for: "a"))
        XCTAssertEqual(cache.count, 0)
    }

    func testTheCacheNeverHoldsMoreThanItsCapacity() {
        let cases: [(capacity: Int, inserted: Int)] = [
            (1, 5),
            (3, 2),
            (3, 3),
            (3, 10),
        ]
        for (capacity, inserted) in cases {
            let cache = BoundedCache<Int, Int>(capacity: capacity)

            for key in 0..<inserted {
                cache.insert(key, for: key)
            }

            XCTAssertEqual(cache.count, min(capacity, inserted), "\(inserted) kept in a cache of \(capacity)")
        }
    }

    func testTheEntryUsedLongestAgoGivesWayWhenTheCacheIsFull() {
        let cache = BoundedCache<String, Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        // "a" is read after "b" was kept, so "b" is now the one used longest ago.
        _ = cache.value(for: "a")

        cache.insert(3, for: "c")

        XCTAssertEqual(cache.value(for: "a"), 1)
        XCTAssertNil(cache.value(for: "b"))
        XCTAssertEqual(cache.value(for: "c"), 3)
    }

    func testKeepingAKeyAgainReplacesItsValueAndForgetsNothingElse() {
        let cache = BoundedCache<String, Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")

        cache.insert(10, for: "a")

        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.value(for: "a"), 10)
        XCTAssertEqual(cache.value(for: "b"), 2)
    }
}
