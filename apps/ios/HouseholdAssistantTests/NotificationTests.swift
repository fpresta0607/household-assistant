// Notifications: what a sealed one says once opened, the reply and reactions a long press
// offers, what the app does with the one chosen, and who is who for the extension.

import XCTest
@testable import HouseholdAssistant

final class NotificationTests: XCTestCase {
    /// What the gateway seals, as push.js writes it.
    private static let opened = #"{"conversation":"family","messageId":"m-00000010","sender":"gia","title":"Rosa","body":"Dinner is ready 🍝"}"#

    func testAnOpenedNotificationSaysWhoWroteWhatWhere() throws {
        let payload = try JSONDecoder().decode(NotificationPayload.self, from: Data(Self.opened.utf8))

        XCTAssertEqual(payload, NotificationPayload(conversation: .family, messageId: "m-00000010", sender: "gia", title: "Rosa", body: "Dinner is ready 🍝"))
        XCTAssertEqual(payload.userInfo, ["conversation": "family", "messageId": "m-00000010"])
    }

    func testOnlyTheFamilyRoomIsAGroup() throws {
        let family = try JSONDecoder().decode(NotificationPayload.self, from: Data(Self.opened.utf8))
        let direct = NotificationPayload(conversation: .direct, messageId: "a-00000011", sender: "corey", title: "Corey", body: "Photo")

        XCTAssertEqual(family.groupName, "The Fam")
        XCTAssertNil(direct.groupName)
    }

    /// Anything else leaves Apple's plain "New message" showing, which still says there is one.
    func testANotificationThatDoesNotSayEverythingIsNotOpened() {
        for json in [
            #"{"conversation":"family","messageId":"m-00000010","title":"Rosa","body":"hi"}"#,
            #"{"conversation":"telegram","messageId":"m-00000010","sender":"gia","title":"Rosa","body":"hi"}"#,
            #"{"conversation":"family","sender":"gia","title":"Rosa","body":"hi"}"#,
            "",
        ] {
            XCTAssertNil(try? JSONDecoder().decode(NotificationPayload.self, from: Data(json.utf8)), json)
        }
    }

    /// The gateway names the category after the conversation (push.js), so these must match it.
    func testEachConversationHasTheCategoryTheGatewayNames() {
        XCTAssertEqual(NotificationActions.category(for: .family), "family-message")
        XCTAssertEqual(NotificationActions.category(for: .direct), "direct-message")
    }

    func testTheReplyFieldSaysWhereTheWordsGo() {
        XCTAssertEqual(NotificationActions.name(of: .family, assistantName: "Corey"), "The Fam")
        XCTAssertEqual(NotificationActions.name(of: .direct, assistantName: "Corey"), "Corey")
    }

    func testEachReactionHasAnActionOfItsOwn() {
        XCTAssertEqual(NotificationActions.reactions, ["\u{2764}\u{FE0F}", "\u{1F44D}", "\u{1F602}"])
        let actions = NotificationActions.reactions.map(NotificationActions.reaction)
        XCTAssertEqual(Set(actions).count, 3)
        XCTAssertFalse(actions.contains(NotificationActions.reply))
        XCTAssertEqual(actions.compactMap(NotificationActions.emoji(of:)), NotificationActions.reactions)
        XCTAssertNil(NotificationActions.emoji(of: NotificationActions.reaction("\u{1F44E}")), "only the three offered")
        XCTAssertNil(NotificationActions.emoji(of: NotificationActions.reply))
    }

    // MARK: - What the person chose

    private static let tapped = "com.apple.UNNotificationDefaultActionIdentifier"

    func testATypedReplyAnswersTheMessageItShowed() {
        let answer = NotificationAnswer(action: NotificationActions.reply, typed: "  On my way \n", conversation: "family", messageId: "m-00000010")

        XCTAssertEqual(answer, .reply("On my way", to: "m-00000010", in: .family))
    }

    /// A notification the extension could not open still knows its conversation by its thread.
    func testAReplyToANotificationThatWasNotOpenedStillReachesItsConversation() {
        let answer = NotificationAnswer(action: NotificationActions.reply, typed: "ok", conversation: "direct", messageId: nil)

        XCTAssertEqual(answer, .reply("ok", to: nil, in: .direct))
    }

    func testAnEmptyReplySendsNothing() {
        for typed in [nil, "", "  \n "] {
            XCTAssertNil(NotificationAnswer(action: NotificationActions.reply, typed: typed, conversation: "family", messageId: "m-00000010"))
        }
    }

    func testAReactionGoesToTheMessageItShowed() {
        let heart = NotificationActions.reaction("\u{2764}\u{FE0F}")

        XCTAssertEqual(
            NotificationAnswer(action: heart, typed: nil, conversation: "family", messageId: "m-00000010"),
            .react("\u{2764}\u{FE0F}", to: "m-00000010", in: .family)
        )
        XCTAssertEqual(
            NotificationAnswer(action: heart, typed: nil, conversation: "family", messageId: nil),
            .open(.family),
            "with no message to react to, it opens the conversation"
        )
    }

    func testATapOpensTheConversation() {
        XCTAssertEqual(NotificationAnswer(action: Self.tapped, typed: nil, conversation: "direct", messageId: "a-00000011"), .open(.direct))
        XCTAssertEqual(NotificationAnswer(action: Self.tapped, typed: nil, conversation: "family", messageId: nil), .open(.family))
    }

    func testANotificationOfNoConversationOfTheAppDoesNothing() {
        XCTAssertNil(NotificationAnswer(action: Self.tapped, typed: nil, conversation: nil, messageId: nil))
        XCTAssertNil(NotificationAnswer(action: NotificationActions.reply, typed: "hi", conversation: "telegram", messageId: "m-00000010"))
    }

    // MARK: - Who is who, for the extension

    private static let household = NotificationPeople(
        me: "franco",
        assistant: "corey",
        names: ["franco": "Leo", "gia": "Rosa", "corey": "Corey", "denise": "Denise"]
    )

    /// The app writes it and the extension reads it, each in its own process.
    func testWhoIsWhoReadsBackAsWritten() throws {
        let read = try JSONDecoder().decode(NotificationPeople.self, from: JSONEncoder().encode(Self.household))

        XCTAssertEqual(read, Self.household)
    }

    func testAFamilyMessageWentToEveryoneElseInTheRoom() {
        XCTAssertEqual(Self.household.recipients(of: "gia", in: .family), ["corey", "denise", "franco"])
        XCTAssertEqual(Self.household.recipients(of: "denise", in: .family), ["corey", "franco", "gia"])
    }

    func testAMessageInThisPhonesOwnThreadWentToItsPerson() {
        XCTAssertEqual(Self.household.recipients(of: "corey", in: .direct), ["franco"])
    }

    func testAFaceIsNamedAfterItsParticipantAndNothingElse() {
        XCTAssertEqual(NotificationPeople.faceFile(for: "gia"), "gia.png")
        XCTAssertEqual(NotificationPeople.faceFile(for: "household-2_b"), "household-2_b.png")
        for id in ["", "../keys", "a/b", "gia.png", ".", String(repeating: "a", count: 65), "gi\u{E0}"] {
            XCTAssertNil(NotificationPeople.faceFile(for: id), id)
        }
    }
}
