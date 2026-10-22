// Rich answers: how an assistant's message splits into Markdown and cards, what each
// card reads from its JSON, what shows while a card is still arriving, and the
// follow-ups an answer offers under its bubble.

import XCTest
@testable import HouseholdAssistant

final class StewardCardTests: XCTestCase {
    private func block(_ json: String) -> String {
        "```steward-card\n\(json)\n```"
    }

    private func segments(_ text: String, isStreaming: Bool = false) -> [MessageSegment] {
        StewardCardParser.segments(in: text, isStreaming: isStreaming)
    }

    /// The one card a block on its own decodes to.
    private func card(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> StewardCard {
        let found = segments(block(json))
        XCTAssertEqual(found.count, 1, "\(found)", file: file, line: line)
        var card: StewardCard?
        if case .card(let only)? = found.first {
            card = only
        }
        return try XCTUnwrap(card, "\(found)", file: file, line: line)
    }

    // MARK: - Splitting

    func testAPlainReplyIsOneMarkdownSegment() {
        let text = "**Tomorrow**\n- 9:00 Team standup\n- 12:30 Lunch with Gia"

        XCTAssertEqual(segments(text), [.markdown(text)])
        XCTAssertEqual(segments(text, isStreaming: true), [.markdown(text)])
    }

    func testWordsAroundCardsKeepTheirOrder() throws {
        let copy = #"{"type":"copy","label":"Gate code","text":"4821"}"#
        let text = "Three weeks so far.\n\n\(block(copy))\n\nAnd the other gate:\n\(block(copy))\nThat is all."

        let gate = StewardCard(content: .copy(CopyCard(label: "Gate code", text: "4821")), skill: nil)
        XCTAssertEqual(segments(text), [
            .markdown("Three weeks so far."),
            .card(gate),
            .markdown("And the other gate:"),
            .card(gate),
            .markdown("That is all."),
        ])
    }

    func testAnUnknownTypeIsShownAsItsJSON() {
        let json = #"{"type":"weather","city":"Boston"}"#

        XCTAssertEqual(segments("Here:\n" + block(json)), [.markdown("Here:"), .code(json)])
    }

    func testMalformedJSONIsShownAsItsText() {
        let json = #"{"type":"table","columns":["Store"]"#

        XCTAssertEqual(segments(block(json)), [.code(json)])
    }

    func testACardMissingWhatItNeedsIsShownAsItsJSON() {
        let cards = [
            // Two values for three labels.
            #"{"type":"chart","kind":"bar","x":["W1","W2","W3"],"series":[{"name":"Spend","values":[142,118]}]}"#,
            // A kind of chart there is no drawing for.
            #"{"type":"chart","kind":"pie","x":["W1"],"series":[{"name":"Spend","values":[142]}]}"#,
            // A checklist with no id cannot be ticked.
            #"{"type":"checklist","title":"Shopping list","items":[{"text":"Milk","done":false}]}"#,
            #"{"type":"copy","label":"Gate code","text":""}"#,
            #"{"type":"table","columns":["Store","Spend"],"rows":[["Corner market"]]}"#,
            #"{"type":"event","title":"Movie night","start":"Friday at 8"}"#,
            // Ends before it starts.
            #"{"type":"event","title":"Movie night","start":"2026-10-16T20:00:00-04:00","end":"2026-10-16T19:00:00-04:00"}"#,
            #"{"type":"product","name":"Bottle","url":"http://example.com/bottle"}"#,
            #"{"type":"product","name":"Bottle","image":"javascript:alert(1)"}"#,
            #"{"type":"scripture","reference":"John 3:16","translation":"BSB","verses":[]}"#,
            #"{"type":"pocketpiggies","card":"loans","total":12}"#,
            #"{"type":"pocketpiggies","card":"budget","month":"October","spent":640,"limit":0}"#,
        ]
        for json in cards {
            XCTAssertEqual(segments(block(json)), [.code(json)], json)
        }
    }

    // MARK: - While a reply streams

    func testACardStillArrivingIsAQuietPlaceholder() {
        let partial = "Here is Saturday.\n```steward-card\n{\"type\":\"checklist\",\"id\":\"sat\",\"items\":[{\"text\":\"Mi"

        XCTAssertEqual(segments(partial, isStreaming: true), [.markdown("Here is Saturday."), .pendingCard])
        XCTAssertEqual(segments("Here is Saturday.\n```steward-card", isStreaming: true), [.markdown("Here is Saturday."), .pendingCard])
        XCTAssertEqual(segments("```steward-card\n{\"type\":\"copy\"}\n``", isStreaming: true), [.pendingCard])
    }

    func testAFenceStillArrivingIsHeldBack() {
        for tail in ["`", "``", "```", "```stew"] {
            XCTAssertEqual(segments("Here is Saturday.\n" + tail, isStreaming: true), [.markdown("Here is Saturday.")], tail)
        }
        // Once the reply is over, what was written is what shows.
        XCTAssertEqual(segments("Here is Saturday.\n```stew"), [.markdown("Here is Saturday.\n```stew")])
    }

    func testACardOnceClosedShowsWhileTheReplyGoesOn() {
        let copy = #"{"type":"copy","text":"4821"}"#

        XCTAssertEqual(segments(block(copy) + "\nAnd", isStreaming: true), [
            .card(StewardCard(content: .copy(CopyCard(label: nil, text: "4821")), skill: nil)),
            .markdown("And"),
        ])
    }

    func testAnUnclosedCardInAFinishedReplyIsReadIfItCanBe() {
        XCTAssertEqual(
            segments("```steward-card\n{\"type\":\"copy\",\"text\":\"4821\"}"),
            [.card(StewardCard(content: .copy(CopyCard(label: nil, text: "4821")), skill: nil))]
        )
        XCTAssertEqual(segments("```steward-card\n{\"type\":\"copy\""), [.code("{\"type\":\"copy\"")])
    }

    func testACardInsideAnOrdinaryCodeBlockIsLeftAsCode() {
        let text = "Send it like this:\n````markdown\n```steward-card\n{\"type\":\"copy\",\"text\":\"4821\"}\n```\n````"

        XCTAssertEqual(segments(text), [.markdown(text)])
        XCTAssertEqual(segments(text, isStreaming: true), [.markdown(text)])
    }

    // MARK: - Markdown tables

    func testAMarkdownTableBecomesANativeTable() {
        let text = """
        By store:

        | Store | Trips | Spend |
        |:---|:---:|---:|
        | Corner market | 5 | $171 |
        | Big box store \\| online | 2 |
        | Farmers market | 3 | $74 | extra |

        That is all.
        """

        let table = TableCard(
            title: nil,
            columns: ["Store", "Trips", "Spend"],
            rows: [
                ["Corner market", "5", "$171"],
                ["Big box store | online", "2", ""],
                ["Farmers market", "3", "$74"],
            ],
            alignments: [.leading, .center, .trailing]
        )
        XCTAssertEqual(segments(text), [
            .markdown("By store:"),
            .card(StewardCard(content: .table(table), skill: nil)),
            .markdown("That is all."),
        ])
    }

    func testATableStillArrivingShowsOnlyItsWholeRows() {
        let header = "| Store | Spend |\n|---|---:|\n"
        let oneRow = TableCard(title: nil, columns: ["Store", "Spend"], rows: [["Corner market", "$171"]], alignments: [.leading, .trailing])

        XCTAssertEqual(
            segments(header + "| Corner market | $171 |\n| Big bo", isStreaming: true),
            [.card(StewardCard(content: .table(oneRow), skill: nil))]
        )
        XCTAssertEqual(segments("Spend:\n| Store | Spend |\n|--", isStreaming: true), [.markdown("Spend:")])
        XCTAssertEqual(segments("Spend:\n| Store | Spend |", isStreaming: true), [.markdown("Spend:")])
        XCTAssertEqual(segments("Spend:\n| Store | Spend |"), [.markdown("Spend:\n| Store | Spend |")])
    }

    func testPipesThatAreNotATableStayText() {
        for text in [
            "Pick one:\n| A | B |\nnot a delimiter",
            "Pick one:\n| A | B |\n|---|---|---|\n| 1 | 2 | 3 |",
        ] {
            XCTAssertEqual(segments(text), [.markdown(text)], text)
        }
    }

    // MARK: - Each card

    func testATableCardReadsItsCellsAndRightAlignsNumbers() throws {
        let stores = try card(#"{"type":"table","title":"By store","columns":["Store","Trips","Spend"],"rows":[["Corner market",5,171],["Big box store",2,146.5],["Farmers market",3,null]]}"#)
        let plans = try card(#"{"type":"table","columns":["Day","Plan","Cost"],"rows":[["Sat","Soccer","$20"],["Sun","Church","Free"]]}"#)

        XCTAssertEqual(stores.content, .table(TableCard(
            title: "By store",
            columns: ["Store", "Trips", "Spend"],
            rows: [["Corner market", "5", "171"], ["Big box store", "2", "146.5"], ["Farmers market", "3", ""]],
            alignments: [.leading, .trailing, .trailing]
        )))
        XCTAssertEqual(plans.content, .table(TableCard(
            title: nil,
            columns: ["Day", "Plan", "Cost"],
            rows: [["Sat", "Soccer", "$20"], ["Sun", "Church", "Free"]],
            alignments: [.leading, .leading, .leading]
        )))
    }

    func testAChartReadsItsSeries() throws {
        let bars = try card(#"{"type":"chart","title":"Grocery spend","kind":"bar","x":["W1","W2","W3"],"series":[{"name":"Spend","values":[142,118,131]}],"unit":"$"}"#)
        let lines = try card(#"{"type":"chart","kind":"line","x":["Sep","Oct"],"series":[{"name":"Spend","values":[455,391]},{"name":"Budget","values":[450,450]}]}"#)

        XCTAssertEqual(bars.content, .chart(ChartCard(
            title: "Grocery spend",
            kind: .bar,
            labels: ["W1", "W2", "W3"],
            series: [ChartCard.Series(name: "Spend", values: [142, 118, 131])],
            unit: "$"
        )))
        XCTAssertEqual(lines.content, .chart(ChartCard(
            title: nil,
            kind: .line,
            labels: ["Sep", "Oct"],
            series: [ChartCard.Series(name: "Spend", values: [455, 391]), ChartCard.Series(name: "Budget", values: [450, 450])],
            unit: nil
        )))
    }

    func testChartValuesReadWithTheirUnit() {
        let cases: [(unit: String?, value: Double, expected: String)] = [
            ("$", 142, "$142"),
            ("$", 1284.5, "$1,284.50"),
            ("€", -20, "-€20"),
            ("%", 12.5, "12.5%"),
            ("°F", 72, "72°F"),
            ("°C", 21.5, "21.5°C"),
            ("kg", 3, "3 kg"),
            ("h", 1.5, "1.5 h"),
            (nil, 1200, "1,200"),
        ]
        for (unit, value, expected) in cases {
            let chart = ChartCard(title: nil, kind: .bar, labels: ["A"], series: [ChartCard.Series(name: "A", values: [value])], unit: unit)
            XCTAssertEqual(chart.text(for: value), expected, "\(unit ?? "none") \(value)")
        }
    }

    func testAChartReadsAsEachLabelWithEverySeriesValueInWords() {
        let chart = ChartCard(
            title: "Practice this week",
            kind: .bar,
            labels: ["Mon", "Tue"],
            series: [ChartCard.Series(name: "Soccer", values: [1.5, 0]), ChartCard.Series(name: "Piano", values: [0.5, 0.5])],
            unit: "h"
        )

        XCTAssertEqual(chart.readings, ["Mon: Soccer 1.5 h, Piano 0.5 h", "Tue: Soccer 0 h, Piano 0.5 h"])
    }

    func testTheXAxisNamesEveryLabelWhileTheyFitAndAReadableFewPastThat() {
        let hours = (0..<24).map { hour in
            "\(hour % 12 == 0 ? 12 : hour % 12) \(hour < 12 ? "AM" : "PM")"
        }
        let cases: [(labels: [String], shown: [String])] = [
            (["W1", "W2", "W3"], ["W1", "W2", "W3"]),
            (["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]),
            (stride(from: 0, to: 24, by: 2).map { hours[$0] }, ["12 AM", "4 AM", "8 AM", "12 PM", "4 PM", "10 PM"]),
            (hours, ["12 AM", "4 AM", "8 AM", "12 PM", "4 PM", "11 PM"]),
            (["Only"], ["Only"]),
        ]
        for (labels, shown) in cases {
            let chart = ChartCard(title: nil, kind: .line, labels: labels, series: [ChartCard.Series(name: "A", values: labels.map { _ in 1 })], unit: nil)

            XCTAssertEqual(chart.axisLabels, shown, "\(labels.count) labels")
        }
    }

    func testValuesSitOnTheBarsOfOneSeriesOfAFewBarsOnly() {
        let cases: [(kind: ChartCard.Kind, labels: Int, series: Int, showsValues: Bool)] = [
            (.bar, 3, 1, true),
            (.bar, 8, 1, true),
            (.bar, 9, 1, false),
            (.bar, 4, 2, false),
            (.line, 3, 1, false),
        ]
        for (kind, labelCount, seriesCount, showsValues) in cases {
            let labels = (0..<labelCount).map { "L\($0)" }
            let series = (0..<seriesCount).map { ChartCard.Series(name: "S\($0)", values: labels.map { _ in 1 }) }
            let chart = ChartCard(title: nil, kind: kind, labels: labels, series: series, unit: nil)

            XCTAssertEqual(chart.showsValuesOnBars, showsValues, "\(kind) of \(labelCount) labels and \(seriesCount) series")
        }
    }

    func testALinesScaleFitsItsValuesWithRoomAndNeverCrossesZeroForThem() {
        let cases: [(values: [Double], floor: Double, ceiling: Double)] = [
            ([68, 67, 72.5, 70], 65.9, 73.6),
            ([0.222, 0.071, 0.326], 0.02, 0.377),
            ([0, 10], 0, 12),
            ([-5, 5], -7, 7),
            ([-10, -2], -11.6, -0.4),
            ([-3, -3], -3.3, -2.7),
            ([72, 72], 64.8, 79.2),
            ([0, 0], 0, 1),
        ]
        for (values, floor, ceiling) in cases {
            let labels = values.indices.map { "L\($0)" }
            let chart = ChartCard(title: nil, kind: .line, labels: labels, series: [ChartCard.Series(name: "A", values: values)], unit: nil)

            XCTAssertEqual(chart.lineRange.lowerBound, floor, accuracy: 0.000_001, "\(values)")
            XCTAssertEqual(chart.lineRange.upperBound, ceiling, accuracy: 0.000_001, "\(values)")
        }
    }

    func testNumbersReadTheWayTheHouseholdWritesThem() {
        let plain: [(Double, String)] = [(0, "0"), (5, "5"), (1200, "1,200"), (1_234_567.891, "1,234,567.89"), (-42.5, "-42.5"), (0.1 + 0.2, "0.3")]
        for (value, expected) in plain {
            XCTAssertEqual(CardNumber.text(value), expected, "\(value)")
        }
        let money: [(Double, String)] = [(640, "$640"), (1284.5, "$1,284.50"), (0.75, "$0.75"), (-12, "-$12"), (999.999, "$1,000")]
        for (value, expected) in money {
            XCTAssertEqual(CardNumber.money(value), expected, "\(value)")
        }
    }

    func testAChecklistReadsItsIdTitleAndItems() throws {
        let list = try card(#"{"type":"checklist","id":"before-trip","title":"Before the trip","items":[{"text":"Sign the permission slip","done":true},{"text":"Pack lunch","done":false}],"skill":"lists"}"#)

        XCTAssertEqual(list.content, .checklist(ChecklistCard(
            id: "before-trip",
            title: "Before the trip",
            items: [ChecklistCard.Item(text: "Sign the permission slip", done: true), ChecklistCard.Item(text: "Pack lunch", done: false)]
        )))
        XCTAssertEqual(list.skill, .lists)
    }

    func testAnEventReadsItsTimes() throws {
        let movie = try card(#"{"type":"event","title":"Movie night","start":"2026-10-16T20:00:00-04:00","end":"2026-10-16T22:00:00-04:00","location":"Living room","skill":"calendar"}"#)
        let dentist = try card(#"{"type":"event","title":"Dentist, Gia","start":"2026-10-15T19:30:00.000Z"}"#)

        let movieNight = EventCard(
            title: "Movie night",
            start: Date(timeIntervalSince1970: 1_792_195_200),
            end: Date(timeIntervalSince1970: 1_792_202_400),
            location: "Living room"
        )
        XCTAssertEqual(movie.content, .event(movieNight))
        XCTAssertEqual(movieNight.calendarEnd, Date(timeIntervalSince1970: 1_792_202_400))
        guard case .event(let appointment) = dentist.content else {
            return XCTFail("not an event: \(dentist)")
        }
        XCTAssertEqual(appointment.start, Date(timeIntervalSince1970: 1_792_092_600))
        XCTAssertNil(appointment.end)
        // A calendar needs an end, and an hour is what a card that names none is given.
        XCTAssertEqual(appointment.calendarEnd, Date(timeIntervalSince1970: 1_792_096_200))
    }

    func testAnEmailReadsLikeAnEmail() throws {
        let school = try card(#"{"type":"email","from":"Maple Elementary <office@maple.example>","to":["Gia","Franco"],"subject":"Field trip on Friday","body":"The bus leaves at 9:00."}"#)
        guard case .email(let email) = school.content else {
            return XCTFail("not an email: \(school)")
        }

        XCTAssertEqual(email.senderName, "Maple Elementary")
        XCTAssertEqual(email.senderAddress, "office@maple.example")
        XCTAssertEqual(email.plainText, "From: Maple Elementary <office@maple.example>\nTo: Gia, Franco\nSubject: Field trip on Friday\n\nThe bus leaves at 9:00.")
        let reply = try XCTUnwrap(email.replyURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        XCTAssertEqual(reply.scheme, "mailto")
        XCTAssertEqual(reply.path, "office@maple.example")
        XCTAssertEqual(reply.queryItems, [URLQueryItem(name: "subject", value: "Re: Field trip on Friday")])
    }

    func testAnEmailFromAPlainNameStillReplies() throws {
        let note = try card(#"{"type":"email","from":"Coach Dan","subject":"Re: Saturday","body":"See you at 9."}"#)
        let bare = try card(#"{"type":"email","from":"coach@club.example","subject":"Saturday","body":"See you at 9."}"#)
        guard case .email(let fromName) = note.content, case .email(let fromAddress) = bare.content else {
            return XCTFail("not emails: \(note) \(bare)")
        }

        XCTAssertEqual(fromName.to, [])
        XCTAssertEqual(fromName.senderName, "Coach Dan")
        XCTAssertNil(fromName.senderAddress)
        let reply = try XCTUnwrap(fromName.replyURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        XCTAssertEqual(reply.path, "")
        XCTAssertEqual(reply.queryItems, [URLQueryItem(name: "subject", value: "Re: Saturday")])
        XCTAssertEqual(fromName.plainText, "From: Coach Dan\nSubject: Re: Saturday\n\nSee you at 9.")
        XCTAssertEqual(fromAddress.senderName, "coach@club.example")
        XCTAssertEqual(fromAddress.senderAddress, "coach@club.example")
    }

    func testACopyBlockReadsItsLabelAndText() throws {
        let gate = try card(#"{"type":"copy","label":"Gate code","text":"4821"}"#)

        XCTAssertEqual(gate.content, .copy(CopyCard(label: "Gate code", text: "4821")))
    }

    func testAProductReadsItsPictureAndLink() throws {
        let bottle = try card(#"{"type":"product","name":"Insulated water bottle","price":"$24.99","store":"Sports Corner","image":"https://example.com/bottle.jpg","url":"https://example.com/bottle"}"#)
        let plain = try card(#"{"type":"product","name":"Insulated water bottle"}"#)

        XCTAssertEqual(bottle.content, .product(ProductCard(
            name: "Insulated water bottle",
            price: "$24.99",
            store: "Sports Corner",
            image: URL(string: "https://example.com/bottle.jpg"),
            url: URL(string: "https://example.com/bottle")
        )))
        XCTAssertEqual(plain.content, .product(ProductCard(name: "Insulated water bottle", price: nil, store: nil, image: nil, url: nil)))
    }

    func testScriptureReadsItsVerses() throws {
        let passage = try card(#"{"type":"scripture","reference":"John 3:16-17","translation":"BSB","verses":[{"n":16,"text":"For God so loved the world."},{"n":17,"text":"For God did not send His Son to condemn the world."}],"link":"https://www.bible.com/bible/3034/JHN.3.16-17.BSB","skill":"scripture"}"#)
        guard case .scripture(let scripture) = passage.content else {
            return XCTFail("not scripture: \(passage)")
        }

        XCTAssertEqual(passage.skill, .scripture)
        XCTAssertEqual(scripture.reference, "John 3:16-17")
        XCTAssertEqual(scripture.translation, "BSB")
        XCTAssertEqual(scripture.verses.map(\.number), [16, 17])
        XCTAssertEqual(scripture.link, URL(string: "https://www.bible.com/bible/3034/JHN.3.16-17.BSB"))
        XCTAssertEqual(scripture.plainText, "John 3:16-17 (BSB)\n16 For God so loved the world. 17 For God did not send His Son to condemn the world.")
    }

    func testPocketPiggiesCards() throws {
        let balance = try card(#"{"type":"pocketpiggies","card":"balance","balance":1284.5,"piggies":[{"name":"Fun","balance":210},{"name":"Savings","balance":860}],"skill":"pocketpiggies"}"#)
        let budget = try card(#"{"type":"pocketpiggies","card":"budget","month":"October","spent":640,"limit":900,"daysLeft":9}"#)
        let spending = try card(#"{"type":"pocketpiggies","card":"spending","categories":[{"name":"Groceries","amount":284},{"name":"Dining","amount":146}]}"#)
        let goal = try card(#"{"type":"pocketpiggies","card":"goal","name":"Beach trip","saved":680,"target":1000,"weekly":40}"#)
        let over = try card(#"{"type":"pocketpiggies","card":"budget","month":"October","spent":950,"limit":900}"#)

        XCTAssertEqual(balance.skill, .pocketpiggies)
        XCTAssertEqual(balance.content, .pocketPiggies(.balance(
            total: 1284.5,
            piggies: [PocketPiggiesCard.Piggy(name: "Fun", balance: 210), PocketPiggiesCard.Piggy(name: "Savings", balance: 860)]
        )))
        XCTAssertEqual(budget.content, .pocketPiggies(.budget(month: "October", spent: 640, limit: 900, daysLeft: 9)))
        XCTAssertEqual(spending.content, .pocketPiggies(.spending(
            title: nil,
            categories: [PocketPiggiesCard.Category(name: "Groceries", amount: 284), PocketPiggiesCard.Category(name: "Dining", amount: 146)]
        )))
        XCTAssertEqual(goal.content, .pocketPiggies(.goal(name: "Beach trip", saved: 680, target: 1000, weekly: 40)))

        func progress(_ card: StewardCard) -> Double? {
            guard case .pocketPiggies(let piggies) = card.content else {
                return nil
            }
            return piggies.progress
        }
        XCTAssertEqual(try XCTUnwrap(progress(budget)), 640.0 / 900.0, accuracy: 0.0001)
        XCTAssertEqual(progress(over), 1)
        XCTAssertEqual(progress(goal), 0.68)
        XCTAssertNil(progress(balance))
    }

    func testAReminderReadsItsWordsAndWhen() throws {
        let pickup = try card(#"{"type":"reminder","text":"Leave for soccer pickup","at":"2026-10-17T17:30:00-04:00"}"#)
        var indianapolis = Calendar(identifier: .gregorian)
        indianapolis.timeZone = TimeZone(identifier: "America/Indiana/Indianapolis")!
        indianapolis.locale = Locale(identifier: "en_US")

        let at = Date(timeIntervalSince1970: 1_792_272_600)

        XCTAssertEqual(pickup.content, .reminder(ReminderCard(text: "Leave for soccer pickup", at: at)))
        XCTAssertNil(pickup.skill)
        XCTAssertEqual(
            MessagePlainText.text(of: block(#"{"type":"reminder","text":"Leave for soccer pickup","at":"2026-10-17T17:30:00-04:00"}"#), calendar: indianapolis),
            "Reminder: Leave for soccer pickup\nSaturday, October 17, 2026, \(ConversationTranscript.clock(at, calendar: indianapolis))"
        )
    }

    func testAReminderMissingItsWordsOrATimeIsShownAsItsJSON() {
        let cards = [
            #"{"type":"reminder","text":"","at":"2026-10-17T17:30:00-04:00"}"#,
            #"{"type":"reminder","text":"Leave for soccer pickup"}"#,
            #"{"type":"reminder","text":"Leave for soccer pickup","at":"Saturday at 5:30"}"#,
        ]
        for json in cards {
            XCTAssertEqual(segments(block(json)), [.code(json)], json)
        }
    }

    func testASkillTheAppDoesNotKnowIsNoBadge() throws {
        let gate = try card(#"{"type":"copy","text":"4821","skill":"astrology"}"#)

        XCTAssertNil(gate.skill)
        XCTAssertEqual(gate.content, .copy(CopyCard(label: nil, text: "4821")))
    }

    func testASermonReadsItsTitleQuoteAndLength() throws {
        let sermon = try card(#"{"type":"sermon","title":"Love that gives","quote":"Love is not measured by what we keep.","minutes":12,"link":"https://sermons.example/12","skill":"sermons"}"#)
        let bare = try card(#"{"type":"sermon","title":"Love that gives"}"#)

        XCTAssertEqual(sermon.content, .sermon(SermonCard(
            title: "Love that gives",
            quote: "Love is not measured by what we keep.",
            minutes: 12,
            link: URL(string: "https://sermons.example/12")
        )))
        XCTAssertEqual(bare.content, .sermon(SermonCard(title: "Love that gives", quote: nil, minutes: nil, link: nil)))
    }

    func testSourcesReadEachLinkAndNameItByItsSite() throws {
        let found = try card(#"{"type":"sources","links":[{"url":"https://www.cityparks.example/pools/hours","title":"City parks"},{"url":"https://news.example/pool"}],"skill":"web"}"#)
        guard case .sources(let sources) = found.content else {
            return XCTFail("not sources: \(found)")
        }

        XCTAssertEqual(sources.links.map(\.name), ["City parks", "news.example"])
        XCTAssertEqual(sources.links.map(\.url.absoluteString), ["https://www.cityparks.example/pools/hours", "https://news.example/pool"])
    }

    func testANewCardMissingWhatItNeedsIsShownAsItsJSON() {
        let cards = [
            #"{"type":"sermon","title":""}"#,
            #"{"type":"sermon","title":"Love that gives","minutes":0}"#,
            #"{"type":"sermon","title":"Love that gives","link":"http://sermons.example/12"}"#,
            #"{"type":"sources","links":[]}"#,
            #"{"type":"sources","links":[{"url":"http://news.example/pool"}]}"#,
            #"{"type":"sources","links":[{"title":"No link"}]}"#,
        ]
        for json in cards {
            XCTAssertEqual(segments(block(json)), [.code(json)], json)
        }
    }

    // MARK: - The skill that answered

    func testAnAnswerWearsTheSkillOfItsFirstCardThatNamesOne() {
        let gate = block(#"{"type":"copy","text":"4821"}"#)
        let dentist = block(#"{"type":"event","title":"Dentist, Gia","start":"2026-10-15T15:30:00-04:00","skill":"calendar"}"#)
        let beach = block(#"{"type":"checklist","id":"beach","items":[{"text":"Towels","done":false}],"skill":"lists"}"#)

        XCTAssertEqual(StewardCardParser.skill(in: "Thursday at 3:30.\n\(gate)\n\(dentist)\n\(beach)", isStreaming: false), .calendar)
    }

    func testAPlainAnswerWearsNoSkill() {
        XCTAssertNil(StewardCardParser.skill(in: "Done. Movie night moved to Saturday.", isStreaming: false))
        XCTAssertNil(StewardCardParser.skill(in: block(#"{"type":"copy","text":"4821"}"#), isStreaming: false))
        XCTAssertNil(StewardCardParser.skill(in: block(#"{"type":"weather","skill":"web"}"#), isStreaming: false), "a card the app cannot draw names nothing")
    }

    func testCardsOnlyOneSkillSendsWearItWithoutNamingIt() throws {
        let passage = try card(#"{"type":"scripture","reference":"Philippians 4:13","translation":"BSB","verses":[{"n":13,"text":"I can do all things through Christ who gives me strength."}]}"#)
        let sermon = try card(#"{"type":"sermon","title":"Love that gives"}"#)
        let budget = try card(#"{"type":"pocketpiggies","card":"budget","month":"October","spent":640,"limit":900}"#)
        let sources = try card(#"{"type":"sources","links":[{"url":"https://news.example/pool"}]}"#)
        let spendChart = try card(#"{"type":"chart","kind":"bar","x":["W1"],"series":[{"name":"Spend","values":[142]}],"skill":"pocketpiggies"}"#)
        let plan = try card(#"{"type":"event","title":"Movie night","start":"2026-10-16T20:00:00-04:00"}"#)

        XCTAssertEqual(passage.skill, .scripture)
        XCTAssertEqual(sermon.skill, .sermons)
        XCTAssertEqual(budget.skill, .pocketpiggies)
        XCTAssertEqual(sources.skill, .web)
        XCTAssertEqual(spendChart.skill, .pocketpiggies, "a card any skill may send wears the one it names")
        XCTAssertNil(plan.skill)
    }

    func testAnAnswerWearsItsSkillOnceTheCardThatNamesItHasClosed() {
        let budget = #"{"type":"pocketpiggies","card":"budget","month":"October","spent":640,"limit":900}"#
        let arriving = "Yes. $640 of $900.\n```steward-card\n" + budget

        XCTAssertNil(StewardCardParser.skill(in: arriving, isStreaming: true))
        XCTAssertEqual(StewardCardParser.skill(in: arriving + "\n```\nNine days left.", isStreaming: true), .pocketpiggies)
    }

    // MARK: - Follow-ups

    private static let tonight = #"{"type":"followups","items":[{"text":"Remind me at 3:45","icon":"reminder"},{"text":"Text Gia"},{"text":"Add movie night","icon":"calendar"}]}"#

    func testFollowUpsAreOfferedUnderTheAnswerAndNotDrawnInIt() throws {
        let text = "Movie night is at 8.\n\n\(block(Self.tonight))"

        XCTAssertEqual(segments(text), [.markdown("Movie night is at 8.")])
        let offered = try XCTUnwrap(StewardCardParser.followups(in: text))
        XCTAssertEqual(offered.items.map(\.text), ["Remind me at 3:45", "Text Gia", "Add movie night"])
        XCTAssertEqual(offered.items.map(\.symbol), ["bell", "sparkles", "calendar"])
    }

    func testEachFollowUpsIconHasItsSymbolAndAnyOtherIsASparkle() throws {
        let json = #"{"type":"followups","items":[{"text":"Add milk","icon":"list"},{"text":"Text Gia","icon":"message"},{"text":"Look it up","icon":"search"}]}"#
        let offered = try XCTUnwrap(StewardCardParser.followups(in: block(json)))

        XCTAssertEqual(offered.items.map(\.symbol), ["checklist", "message", "magnifyingglass"])
        XCTAssertEqual(
            StewardCardParser.followups(in: block(#"{"type":"followups","items":[{"text":"Book it","icon":"rocket"}]}"#))?.items.map(\.symbol),
            ["sparkles"]
        )
    }

    func testAtMostThreeFollowUpsAreOfferedAndTheirWordsAreTrimmed() throws {
        let json = #"{"type":"followups","items":[{"text":"  One  "},{"text":"Two"},{"text":"Three"},{"text":"Four"}]}"#

        XCTAssertEqual(StewardCardParser.followups(in: block(json))?.items.map(\.text), ["One", "Two", "Three"])
    }

    func testFollowUpsMissingWhatTheyNeedAreShownAsTheirJSON() {
        let cards = [
            #"{"type":"followups","items":[]}"#,
            #"{"type":"followups","items":[{"text":"  "}]}"#,
            #"{"type":"followups","items":[{"icon":"reminder"}]}"#,
            #"{"type":"followups"}"#,
        ]
        for json in cards {
            XCTAssertEqual(segments(block(json)), [.code(json)], json)
            XCTAssertNil(StewardCardParser.followups(in: block(json)), json)
        }
    }

    func testOnlyTheFirstFollowUpsAreOffered() {
        let later = #"{"type":"followups","items":[{"text":"Later"}]}"#

        XCTAssertEqual(
            StewardCardParser.followups(in: "\(block(Self.tonight))\n\(block(later))")?.items.map(\.text),
            ["Remind me at 3:45", "Text Gia", "Add movie night"]
        )
    }

    func testAnAnswerWithoutFollowUpsOffersNone() {
        XCTAssertNil(StewardCardParser.followups(in: "Done. Movie night moved to Saturday."))
        XCTAssertNil(StewardCardParser.followups(in: block(#"{"type":"copy","text":"4821"}"#)))
        XCTAssertNil(
            StewardCardParser.followups(in: "Like this:\n````\n\(block(Self.tonight))\n````"),
            "follow-ups inside an ordinary code block are its text"
        )
    }

    func testFollowUpsStillArrivingShowNoPlaceholder() {
        let arriving = "Movie night is at 8.\n```steward-card\n{\"type\":\"followups\",\"items\":[{\"text\":\"Remind"

        XCTAssertEqual(segments(arriving, isStreaming: true), [.markdown("Movie night is at 8.")])
        XCTAssertEqual(segments("Movie night is at 8.\n\(block(Self.tonight))", isStreaming: true), [.markdown("Movie night is at 8.")])
    }
}
