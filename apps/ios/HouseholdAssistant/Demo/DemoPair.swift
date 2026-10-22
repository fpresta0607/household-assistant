#if DEBUG
// The made-up household's two assistants on their direct line, in the shape the
// household-app plugin answers `household-app.line` with (notes.js timeline): Corey logs
// three seedlings at once and corrects one, hands Denise a question that she sees, answers
// and marks done, takes a question Leo asked them both, and Denise hands him one of
// Rosa's, which he has just seen. Its last step is four minutes before the moment it is made,
// so the family room's marker shows. Every word here is invented.

import Foundation

struct DemoPair {
    static let method = "household-app.line"

    /// Every step, oldest first.
    private let events: [JSONValue]

    init(at moment: Date) {
        let now = Int((moment.timeIntervalSince1970 * 1000).rounded())
        let minute = 60_000
        let library = Self.line("hn-demo0004", "Handoffs", "Can you check whether the library books are due this week?", owner: "denise")
        let bakeSale = Self.line("hn-demo0005", "Handoffs", "Is the bake sale tray on Leo's list for Saturday?", owner: "corey")
        events = [
            Self.step(1, now - 190 * minute, "corey", "added", for: "franco", line: Self.line("hn-demo0001", "Seedlings", "4 cm", item: "Basil")),
            Self.step(2, now - 190 * minute + 1, "corey", "added", for: "franco", line: Self.line("hn-demo0002", "Seedlings", "2 cm", item: "Thyme")),
            Self.step(3, now - 190 * minute + 2, "corey", "added", for: "franco", line: Self.line("hn-demo0003", "Seedlings", "6 cm", item: "Chives")),
            Self.step(4, now - 186 * minute, "corey", "corrected", for: "franco", line: Self.line("hn-demo0001", "Seedlings", "5 cm", item: "Basil")),
            Self.step(5, now - 41 * minute, "corey", "handed", for: "franco", line: library),
            Self.step(6, now - 41 * minute + 2_000, "denise", "seen", line: library),
            Self.step(7, now - 40 * minute, "denise", "replied", line: library, reply: "Two are due Friday, the rest next week."),
            Self.step(8, now - 39 * minute, "denise", "done", for: "gia", line: library),
            Self.step(9, now - 12 * minute, "corey", "claimed", for: "franco", message: "m-demo-0001"),
            Self.step(10, now - 5 * minute, "denise", "handed", for: "gia", line: bakeSale),
            Self.step(11, now - 4 * minute, "corey", "seen", line: bakeSale),
        ]
    }

    /// The plugin's page: the newest `limit` steps before `before`, oldest first, and whether
    /// any are older.
    func answer(_ params: JSONValue) -> JSONValue {
        let before = params["before"]?.intValue ?? .max
        let limit = params["limit"]?.intValue ?? 100
        let older = events.filter { ($0["at"]?.intValue ?? 0) < before }
        return .object([
            "events": .array(Array(older.suffix(limit))),
            "more": .bool(older.count > limit),
        ])
    }

    /// When the line last moved, as every sync and history page carries it.
    var mark: JSONValue {
        .object(["lastAt": events.last?["at"] ?? .null])
    }

    private static func step(
        _ number: Int,
        _ at: Int,
        _ by: String,
        _ kind: String,
        for person: String? = nil,
        line: JSONValue? = nil,
        reply: String? = nil,
        message: String? = nil
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .string("ns-demo-\(number)"),
            "at": .number(Double(at)),
            "by": .string(by),
            "kind": .string(kind),
        ]
        fields["for"] = person.map(JSONValue.string)
        fields["line"] = line
        fields["reply"] = reply.map(JSONValue.string)
        fields["message"] = message.map(JSONValue.string)
        return .object(fields)
    }

    private static func line(_ id: String, _ topic: String, _ text: String, item: String? = nil, owner: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = ["id": .string(id), "topic": .string(topic), "text": .string(text)]
        fields["item"] = item.map(JSONValue.string)
        fields["owner"] = owner.map(JSONValue.string)
        return .object(fields)
    }
}
#endif
