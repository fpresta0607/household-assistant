// A list in an assistant's reply whose every item starts with a time becomes tidy rows
// with the time in a chip. What counts as a time, what stays Markdown, and how a list
// still arriving is shown line by line.

import XCTest
@testable import HouseholdAssistant

final class TimeRowsTests: XCTestCase {
    func testAListOfTimesBecomesRowsAndTheWordsAroundItStayAsWritten() {
        let markdown = "**Tonight**\n- 4:10 PM Gia lands\n- 6:30 PM Dinner at home\n- 8:00 PM Movie night\n\nWant a reminder to leave at 3:45?"

        let blocks = TimeRows.blocks(in: markdown, isStreaming: false)

        XCTAssertEqual(blocks, [
            .markdown("**Tonight**\n"),
            .rows([
                TimeRows.Row(time: "4:10 PM", words: "Gia lands"),
                TimeRows.Row(time: "6:30 PM", words: "Dinner at home"),
                TimeRows.Row(time: "8:00 PM", words: "Movie night"),
            ]),
            .markdown("\nWant a reminder to leave at 3:45?"),
        ])
    }

    func testTimesAreReadHoweverTheyAreWrittenAndShownTheOneWay() {
        let items: [(item: String, row: TimeRows.Row)] = [
            ("- 9:00 Team standup", TimeRows.Row(time: "9:00", words: "Team standup")),
            ("- 17:45 Pick up from soccer", TimeRows.Row(time: "17:45", words: "Pick up from soccer")),
            ("* 4:10pm Gia lands", TimeRows.Row(time: "4:10 PM", words: "Gia lands")),
            ("+ 7:05 a.m. Bus", TimeRows.Row(time: "7:05 AM", words: "Bus")),
            ("- **4:10 PM** Gia lands", TimeRows.Row(time: "4:10 PM", words: "Gia lands")),
            ("- 8:00 PM - Movie night", TimeRows.Row(time: "8:00 PM", words: "Movie night")),
            ("- 8:00 PM \u{2014} Movie night", TimeRows.Row(time: "8:00 PM", words: "Movie night")),
            ("- 8:00 PM: Movie night", TimeRows.Row(time: "8:00 PM", words: "Movie night")),
        ]
        for shot in items {
            XCTAssertEqual(TimeRows.blocks(in: shot.item, isStreaming: false), [.rows([shot.row])], shot.item)
        }
    }

    func testWhatIsNotATimeLeavesTheWholeListAsMarkdown() {
        let lists = [
            "- 4:10 PM Gia lands\n- Dinner at home",
            "- 25:00 Too late",
            "- 13:00 PM Not a time",
            "- 4:7 Gia lands",
            "- 4:10",
            "- 4:10 PM",
            "- 4:10PMish Gia lands",
            "- 1 cup flour",
            "  - 4:10 PM Indented under something",
        ]
        for markdown in lists {
            XCTAssertEqual(TimeRows.blocks(in: markdown, isStreaming: false), [.markdown(markdown)], markdown)
        }
    }

    func testAReplyWithNoListOfTimesIsLeftExactlyAsItIs() {
        let markdown = "Done. I will remind you at 5:30 PM \u{23F0}\n"

        XCTAssertEqual(TimeRows.blocks(in: markdown, isStreaming: false), [.markdown(markdown)])
        XCTAssertEqual(TimeRows.blocks(in: markdown, isStreaming: true), [.markdown(markdown)])
        XCTAssertEqual(TimeRows.blocks(in: "", isStreaming: false), [])
    }

    func testWhileTheReplyArrivesAnItemThatMayStillBeATimeWaitsForItsLineToEnd() {
        let blocks = TimeRows.blocks(in: "**Tonight**\n- 4:10 PM Gia lands\n- 6:3", isStreaming: true)

        XCTAssertEqual(blocks, [.markdown("**Tonight**\n"), .rows([TimeRows.Row(time: "4:10 PM", words: "Gia lands")])])
        XCTAssertEqual(TimeRows.blocks(in: "**Tonight**\n- ", isStreaming: true), [.markdown("**Tonight**\n")])
        XCTAssertEqual(TimeRows.blocks(in: "**Tonight**\n-", isStreaming: true), [.markdown("**Tonight**\n")])
    }

    func testWhileTheReplyArrivesAnythingElseShowsAsItComes() {
        XCTAssertEqual(
            TimeRows.blocks(in: "- 4:10 PM Gia lands\nWant a rem", isStreaming: true),
            [.rows([TimeRows.Row(time: "4:10 PM", words: "Gia lands")]), .markdown("Want a rem")]
        )
        XCTAssertEqual(TimeRows.blocks(in: "Here is what I found\n- Milk an", isStreaming: true), [.markdown("Here is what I found\n- Milk an")])
    }

    func testAFinishedReplysLastItemNeedsNoLineEnd() {
        XCTAssertEqual(TimeRows.blocks(in: "- 6:3", isStreaming: false), [.markdown("- 6:3")])
        XCTAssertEqual(TimeRows.blocks(in: "- 6:30 PM Dinner", isStreaming: false), [.rows([TimeRows.Row(time: "6:30 PM", words: "Dinner")])])
    }
}
