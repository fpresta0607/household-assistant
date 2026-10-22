// A table: from a `table` card, or from an ordinary Markdown table in the reply, so both
// are drawn the same native way.
//
// A card's cells may be words or numbers. A column of numbers, money and percentages
// reads right-aligned, the way a person lines up sums; the first column never does.

import Foundation

struct TableCard: Decodable, Equatable, Sendable {
    enum Alignment: Equatable, Sendable {
        case leading, center, trailing
    }

    let title: String?
    let columns: [String]
    let rows: [[String]]
    let alignments: [Alignment]

    init(title: String?, columns: [String], rows: [[String]], alignments: [Alignment]) {
        self.title = title
        self.columns = columns
        self.rows = rows
        self.alignments = alignments
    }

    private enum CodingKeys: String, CodingKey {
        case title, columns, rows
    }

    /// A cell as the card wrote it: words, a number, or nothing.
    private struct Cell: Decodable {
        let text: String
        let isNumber: Bool

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                text = ""
                isNumber = false
            } else if let number = try? container.decode(Double.self) {
                text = CardNumber.text(number)
                isNumber = true
            } else {
                text = try container.decode(String.self)
                isNumber = false
            }
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let columns = try container.decode([String].self, forKey: .columns)
        let cells = try container.decode([[Cell]].self, forKey: .rows)
        guard !columns.isEmpty, cells.allSatisfy({ $0.count == columns.count }) else {
            throw DecodingError.dataCorruptedError(forKey: .rows, in: container, debugDescription: "every row needs one cell per column")
        }
        title = try container.decodeIfPresent(String.self, forKey: .title)
        self.columns = columns
        rows = cells.map { $0.map(\.text) }
        alignments = columns.indices.map { column in
            let filled = cells.map { $0[column] }.filter { !$0.text.isEmpty }
            let isNumeric = column > 0 && !filled.isEmpty && filled.allSatisfy { $0.isNumber || Self.looksNumeric($0.text) }
            return isNumeric ? .trailing : .leading
        }
    }

    /// A Markdown table from its header, delimiter and body rows, or nil when the delimiter
    /// is not one for this header. Rows short of cells are filled and long ones cut, as
    /// GitHub reads them.
    static func markdown(header: String, delimiter: String, rows: [String]) -> TableCard? {
        let columns = cells(of: header)
        let marks = cells(of: delimiter)
        guard !columns.isEmpty, marks.count == columns.count else {
            return nil
        }
        var alignments: [Alignment] = []
        for mark in marks {
            let dashes = mark.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else {
                return nil
            }
            switch (mark.hasPrefix(":"), mark.hasSuffix(":")) {
            case (true, true):
                alignments.append(.center)
            case (false, true):
                alignments.append(.trailing)
            default:
                alignments.append(.leading)
            }
        }
        let body = rows.map { row in
            let found = cells(of: row)
            return (0..<columns.count).map { $0 < found.count ? found[$0] : "" }
        }
        return TableCard(title: nil, columns: columns, rows: body, alignments: alignments)
    }

    /// One row's cells: split on the pipes that are not escaped, with the outer ones gone.
    private static func cells(of row: String) -> [String] {
        var line = row.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("|") {
            line.removeFirst()
        }
        if line.hasSuffix("|"), !line.hasSuffix("\\|") {
            line.removeLast()
        }
        var cells: [String] = []
        var current = ""
        var isEscaped = false
        for character in line {
            if isEscaped {
                current.append(character == "|" ? "|" : "\\\(character)")
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if isEscaped {
            current.append("\\")
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// "$171", "-12.5", "40%", "1,200": a number once its sign, currency and percent are set aside.
    private static func looksNumeric(_ text: String) -> Bool {
        var core = Substring(text)
        if let first = core.first, "+-".contains(first) {
            core.removeFirst()
        }
        if let first = core.first, "$€£¥".contains(first) {
            core.removeFirst()
        }
        if core.last == "%" {
            core.removeLast()
        }
        return core.contains(where: \.isNumber) && core.allSatisfy { $0.isNumber || $0 == "," || $0 == "." }
    }
}
