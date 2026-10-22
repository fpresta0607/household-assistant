// Search stays in the composer. A bounded list floats above it until a match is picked.
// A late result never selects a message for a newer query or reopens a closed search.

import Observation
import SwiftUI

@MainActor
@Observable
final class ThreadSearchModel {
    private static let pause: Duration = .milliseconds(150)

    private(set) var isOpen = false
    var query = "" {
        didSet { if query != oldValue { changedRequest() } }
    }
    var filter: ThreadSearch.Filter = .all {
        didSet { if filter != oldValue { changedRequest() } }
    }
    private(set) var matches: [ThreadSearch.Match] = []
    private(set) var searched: String?
    private(set) var searchedFilter: ThreadSearch.Filter?
    private(set) var current: Int?
    /// Also invalidates a pending jump when the query changes or search closes.
    private(set) var shows = 0
    var isListShown = true
    var isReadingOlder = false
    private var submitWhenReady = false
    private var generation = 0
    private var nextBefore: Int?
    private var completedOlderRequest = 0
    private(set) var olderRequest = 0
    private(set) var historyError = false

    var canSearchOlder: Bool { nextBefore != nil && matches.count < ThreadSearch.mostMatches }

    func searchOlder() {
        guard canSearchOlder, !isReadingOlder else { return }
        olderRequest += 1
    }

    var hasQuery: Bool { !ThreadSearch.bare(query).isEmpty }

    var isReady: Bool { searched == query && searchedFilter == filter }

    var currentMatch: ThreadSearch.Match? {
        guard isReady else { return nil }
        return current.flatMap { matches.indices.contains($0) ? matches[$0] : nil }
    }

    var position: String {
        guard isReady else { return "Searching" }
        if let current { return "\(current + 1) of \(matches.count)" }
        return matches.count == 1 ? "1 result" : "\(matches.count) results"
    }

    func open() {
        query = ""
        filter = .all
        matches = []
        searched = nil
        searchedFilter = nil
        current = nil
        submitWhenReady = false
        isListShown = true
        isOpen = true
    }

    func close() {
        generation += 1
        nextBefore = nil
        isReadingOlder = false
        isOpen = false
        query = ""
        matches = []
        searched = nil
        searchedFilter = nil
        current = nil
        submitWhenReady = false
        shows += 1
    }

    private func changedRequest() {
        generation += 1
        nextBefore = nil
        olderRequest = 0
        completedOlderRequest = 0
        historyError = false
        isReadingOlder = false
        current = nil
        submitWhenReady = false
        isListShown = true
        shows += 1
    }

    func search(
        _ messages: [RoomMessage], heard: [String: String], hasOlder: Bool = false,
        loadPage: ((Int) async throws -> RoomHistoryPage)? = nil
    ) async {
        let query = self.query
        let filter = self.filter
        let generation = self.generation
        try? await Task.sleep(for: Self.pause)
        guard !Task.isCancelled, isOpen, self.generation == generation else { return }
        let continuing = olderRequest > completedOlderRequest && nextBefore != nil
        var found: [ThreadSearch.Match]
        if continuing {
            found = matches
        } else {
            found = await Task.detached(priority: .userInitiated) {
                ThreadSearch.matches(of: query, in: messages, heard: heard, filter: filter)
            }.value
        }
        var before = continuing ? nextBefore : (hasOlder ? messages.compactMap(\.rev).min() : nil)
        historyError = false
        // Each query holds only snippets plus one page, never a full conversation.
        // Twenty pages per request bounds network work; the person may continue older.
        if hasQuery, let loadPage, before != nil, found.count < ThreadSearch.mostMatches {
            isReadingOlder = true
            for _ in 0..<RoomModel.pageBudget {
                guard !Task.isCancelled, isOpen, self.generation == generation,
                      let cursor = before else { break }
                do {
                    let page = try await loadPage(cursor)
                    guard !Task.isCancelled, isOpen, self.generation == generation else { return }
                    var window = RoomThread(.direct)
                    window.load(page)
                    let pageMessages = window.messages
                    let older = await Task.detached(priority: .userInitiated) {
                        ThreadSearch.matches(of: query, in: pageMessages, heard: heard, filter: filter)
                    }.value
                    let known = Set(found.map(\.id))
                    found.append(contentsOf: older.filter { !known.contains($0.id) }.prefix(ThreadSearch.mostMatches - found.count))
                    let oldest = page.messages.map(\.rev).min()
                    before = page.hasMore && (oldest.map { $0 < cursor } ?? false) ? oldest : nil
                    if before == nil || found.count == ThreadSearch.mostMatches { break }
                } catch {
                    if !Task.isCancelled { historyError = true }
                    break
                }
            }
        } else if !hasQuery {
            before = nil
        }
        guard !Task.isCancelled, isOpen, self.generation == generation else { return }
        nextBefore = before
        completedOlderRequest = olderRequest
        isReadingOlder = false
        let shown = currentMatch?.messageId
        matches = found
        searched = query
        searchedFilter = filter
        current = shown.flatMap { id in found.firstIndex { $0.messageId == id } }
        if submitWhenReady {
            submitWhenReady = false
            pick(0)
        }
    }

    /// Both submit controls open the first match. If typing has not settled yet,
    /// wait for this query's results instead of picking a stale result.
    func submit() {
        guard hasQuery else { return }
        isListShown = true
        if isReady {
            pick(0)
        } else {
            submitWhenReady = true
        }
    }

    func pick(_ index: Int) {
        guard isOpen, isReady, matches.indices.contains(index) else { return }
        current = index
        isListShown = false
        shows += 1
    }

    func step(isOlder: Bool) {
        guard isReady, let next = ThreadSearch.step(from: current, isOlder: isOlder, in: matches) else { return }
        pick(next)
    }
}

