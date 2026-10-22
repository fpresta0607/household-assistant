// A bar or line chart: labels along the bottom, one or more named series of values over
// them, and the unit the values are in. A series that does not have one value per label
// cannot be drawn, so the card is refused and shows as its JSON instead.

import Foundation

struct ChartCard: Decodable, Equatable, Sendable {
    enum Kind: String, Decodable, Sendable {
        case bar, line
    }

    struct Series: Decodable, Equatable, Sendable {
        let name: String
        let values: [Double]
    }

    let title: String?
    let kind: Kind
    let labels: [String]
    let series: [Series]
    /// "$", "€", "£" and "¥" go before a value, "%" and a degree such as "°F" right after
    /// it, anything else after a space.
    let unit: String?

    init(title: String?, kind: Kind, labels: [String], series: [Series], unit: String?) {
        self.title = title
        self.kind = kind
        self.labels = labels
        self.series = series
        self.unit = unit
    }

    private enum CodingKeys: String, CodingKey {
        case title, kind, x, series, unit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let labels = try container.decode([String].self, forKey: .x)
        let series = try container.decode([Series].self, forKey: .series)
        guard !labels.isEmpty, !series.isEmpty, series.allSatisfy({ $0.values.count == labels.count }) else {
            throw DecodingError.dataCorruptedError(forKey: .series, in: container, debugDescription: "every series needs one value per label")
        }
        title = try container.decodeIfPresent(String.self, forKey: .title)
        kind = try container.decode(Kind.self, forKey: .kind)
        self.labels = labels
        self.series = series
        unit = try container.decodeIfPresent(String.self, forKey: .unit)
    }

    /// A value as the chart labels it: "$142", "12.5%", "72°F", "3 kg".
    func text(for value: Double) -> String {
        guard let unit, !unit.isEmpty else {
            return CardNumber.text(value)
        }
        if ["$", "€", "£", "¥"].contains(unit) {
            return CardNumber.money(value, symbol: unit)
        }
        if unit == "%" || unit.hasPrefix("°") {
            return CardNumber.text(value) + unit
        }
        return CardNumber.text(value) + " " + unit
    }

    /// Each label with every series' value at it, in words, as Copy writes the chart and
    /// VoiceOver reads it: "Sep: Groceries $640, Dining $210".
    var readings: [String] {
        labels.indices.map { index in
            labels[index] + ": " + series.map { "\($0.name) \(text(for: $0.values[index]))" }.joined(separator: ", ")
        }
    }

    /// The labels the x axis names: every one while they fit across the bubble, else every
    /// second, third or more, always with the first and the last, so a day of hours reads
    /// as a few times rather than a smear. Short labels like "Mon" fit nine across, ones
    /// like "12 AM" six.
    var axisLabels: [String] {
        let longest = labels.map(\.count).max() ?? 0
        let most = max(Self.axisCharacters / (longest + 2), 2)
        guard labels.count > most else {
            return labels
        }
        let step = (labels.count + most - 1) / most
        let last = labels.count - 1
        var shown = Array(stride(from: 0, to: last, by: step))
        // The last always shows, so the one before it goes when it would sit closer to it
        // than the rest sit to each other.
        if let before = shown.last, before > 0, last - before < step {
            shown.removeLast()
        }
        return (shown + [last]).map { labels[$0] }
    }

    /// About how many characters, gaps included, the x axis has room for in a bubble.
    private static let axisCharacters = 48

    /// Values sit on top of the bars of one series while there are few enough to read. Two
    /// series' values side by side run into each other, so those charts get an axis, as
    /// do more bars.
    var showsValuesOnBars: Bool {
        kind == .bar && series.count == 1 && labels.count <= Self.mostValuedBars
    }

    private static let mostValuedBars = 8

    /// What a line's scale runs over: its lowest to highest value with a fifth of their
    /// spread as room either side, so a day's few degrees fill the chart rather than lie
    /// flat on a scale from zero, and the top value's dot and axis label stay inside it.
    /// The room never takes values of zero and up below zero, nor values all below zero
    /// above it. One value alone gets a tenth of itself either side, and nothing but zeros
    /// runs from zero to one.
    var lineRange: ClosedRange<Double> {
        let values = series.flatMap(\.values)
        let lowest = values.min() ?? 0
        let highest = values.max() ?? 0
        let spread = highest - lowest
        let room = spread > 0 ? spread / 5 : (highest == 0 ? 1 : abs(highest) / 10)
        let floor = lowest >= 0 ? max(lowest - room, 0) : lowest - room
        let ceiling = highest < 0 ? min(highest + room, 0) : highest + room
        return floor...ceiling
    }
}
