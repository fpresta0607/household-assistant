// The steward-cards skill's own examples, read from the repository: every card the skill
// shows the assistants how to write is one this app draws, never its raw JSON, and each of
// its charts is a chart. The skill is found relative to this source file, as the fixtures
// are, so the same test runs under `swift test` on Linux and on the simulator.

import XCTest
@testable import HouseholdAssistant

final class SkillCardExamplesTests: XCTestCase {
    private static let skill = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("deploy/openclaw/skills/steward-cards/SKILL.md")

    /// Every ```steward-card block in the skill, its fences included, in the skill's order.
    private func examples() throws -> [String] {
        let lines = try String(contentsOf: Self.skill, encoding: .utf8).components(separatedBy: .newlines)
        var examples: [String] = []
        var open: [String]?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var block = open {
                block.append(line)
                open = block
                if trimmed == "```" {
                    examples.append(block.joined(separator: "\n"))
                    open = nil
                }
            } else if trimmed == StewardCardParser.fence {
                open = [line]
            }
        }
        return examples
    }

    func testEveryExampleInTheSkillIsACardThisAppDraws() throws {
        // Arrange
        let examples = try examples()
        XCTAssertFalse(examples.isEmpty, "no steward-card block in \(Self.skill.path)")

        for example in examples {
            // Act
            let segments = StewardCardParser.segments(in: example, isStreaming: false)

            // Assert: follow-ups are chips under the bubble, never a segment.
            if segments.isEmpty {
                XCTAssertNotNil(StewardCardParser.followups(in: example), example)
                continue
            }
            XCTAssertEqual(segments.count, 1, example)
            guard case .card? = segments.first else {
                XCTFail("shown as its JSON: \(example)")
                continue
            }
        }
    }

    func testEveryChartExampleInTheSkillIsAChart() throws {
        // Arrange
        let examples = try examples().filter { $0.contains(#""type":"chart""#) }

        // Act
        let charts = examples.compactMap { example -> ChartCard? in
            guard case .card(let card)? = StewardCardParser.segments(in: example, isStreaming: false).first, case .chart(let chart) = card.content else {
                XCTFail("not a chart: \(example)")
                return nil
            }
            return chart
        }

        // Assert: weekly bars, the thermostat over a day, prices, a schedule and two months.
        XCTAssertEqual(charts.count, 5)
        XCTAssertEqual(charts.map(\.unit), ["$", "°F", "$", "h", "$"])
        XCTAssertEqual(charts.map(\.kind), [.bar, .line, .bar, .bar, .bar])
        XCTAssertEqual(charts.map(\.series.count), [1, 1, 1, 2, 2])
        XCTAssertEqual(charts.dropFirst().first?.labels.count, 12, "the thermostat every two hours")
    }
}
