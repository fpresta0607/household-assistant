// Typing @ in the composer: when it offers someone, whom it offers and in what order,
// and what picking one leaves in the draft. And what asking the assistant about a message
// writes there.

import XCTest
@testable import HouseholdAssistant

final class MentionTests: XCTestCase {
    private let room = [
        RoomParticipant(id: "franco", name: "Franco", kind: .person, isOwner: true),
        RoomParticipant(id: "gia", name: "Gia", kind: .person, isOwner: false),
        RoomParticipant(id: "corey", name: "Corey", kind: .assistant, isOwner: false, emoji: "\u{1F989}"),
        RoomParticipant(id: "denise", name: "Denise", kind: .assistant, isOwner: false, emoji: "\u{1F338}"),
    ]
    private let me = RoomSelf(person: "franco", assistant: "corey")

    func testAnAtStartingAWordAtTheEndOfTheDraftAsksWhoIsMeant() {
        let drafts: [(draft: String, query: String?)] = [
            ("@", ""),
            ("Can @", ""),
            ("Can @co", "co"),
            ("Thanks\n@De", "De"),
            ("Can @Corey pick up Luca", nil),
            ("Can @Corey ", nil),
            ("mail franco@example", nil),
            ("Can we", nil),
            ("", nil),
        ]
        for shot in drafts {
            XCTAssertEqual(Mention.query(in: shot.draft), shot.query, shot.draft)
        }
    }

    func testEveryoneIsOfferedThisPhonesAssistantFirstAndItsOwnerLast() {
        let offered = Mention.candidates(matching: "", participants: room, me: me)
        XCTAssertEqual(offered.map(\.participant.id), ["corey", "denise", "gia", "franco"])
        XCTAssertEqual(offered.map(\.role), ["Your assistant", "Gia's assistant", nil, "You"])
    }

    func testWhatIsTypedNarrowsTheOfferByTheStartOfTheName() {
        XCTAssertEqual(Mention.candidates(matching: "d", participants: room, me: me).map(\.participant.id), ["denise"])
        XCTAssertEqual(Mention.candidates(matching: "GI", participants: room, me: me).map(\.participant.id), ["gia"])
        XCTAssertEqual(Mention.candidates(matching: "x", participants: room, me: me).map(\.participant.id), [])
    }

    func testWithNobodyKnownYetNothingIsOffered() {
        XCTAssertEqual(Mention.candidates(matching: "", participants: [], me: nil).count, 0)
    }

    func testPickingSomeoneKeepsTheAtAndWritesTheirNameAfterIt() {
        XCTAssertEqual(Mention.inserting("Corey", into: "Can @co"), "Can @Corey ")
        XCTAssertEqual(Mention.inserting("Gia", into: "@"), "@Gia ")
        XCTAssertEqual(Mention.inserting("Denise", into: "Thanks\n@"), "Thanks\n@Denise ")
        XCTAssertEqual(Mention.inserting("Gia", into: "No mention here"), "No mention here")
    }

    func testWhatPickingSomeoneLeavesIsAMentionOfThem() {
        let draft = Mention.inserting("Corey", into: "Can @co")
        XCTAssertEqual(Mention.spans(in: draft, participants: room, me: me).map(\.participant.id), ["corey"])
    }

    func testAskingAnAssistantMentionsThemFirstUnlessTheDraftAlreadyDoes() {
        let drafts: [(draft: String, asked: String)] = [
            ("", "@Corey "),
            ("what time is it on?", "@Corey what time is it on?"),
            ("@corey what time is it on?", "@corey what time is it on?"),
            ("ask @Corey later", "ask @Corey later"),
            ("mail franco@Corey", "@Corey mail franco@Corey"),
        ]
        for shot in drafts {
            XCTAssertEqual(Mention.asking("Corey", in: shot.draft), shot.asked, shot.draft)
        }
    }
}
