// The demo household is made up, so any picture of the app can be shown: nothing the
// demo, the captured fixtures or the tests draw names a real household member, by name,
// by initial, in an address or in a mention.
//
// The real household's people keep their first names as their ids (HouseholdMember),
// which stored memory and sessions are keyed by, so the names looked for here are read
// from the ids rather than written out.

import Foundation
import XCTest
@testable import HouseholdAssistant

final class MadeUpHouseholdTests: XCTestCase {
    private static let iosDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Where the demo, the screenshots and the tests take their people from.
    private static let sources = [
        "HouseholdAssistant/Demo",
        "HouseholdAssistant/Protocol/Fixtures",
        "HouseholdAssistantTests",
        "HouseholdAssistantUITests",
    ]

    func testNothingTheDemoFixturesOrTestsDrawNamesARealHouseholdMember() throws {
        // A name as it is written for people: capitalized, at the start of an address, or
        // after an @. A lowercase name on its own is an id, which stays. A word starts after
        // anything but a letter or a digit, and also after an escape such as "\n", whose
        // letter would otherwise hide it.
        let start = #"(?:(?<![A-Za-z0-9_])|(?<=\\[nrt]))"#
        let pattern = HouseholdMember.allCases.map { member in
            let name = NSRegularExpression.escapedPattern(for: member.rawValue)
            let written = NSRegularExpression.escapedPattern(for: member.rawValue.prefix(1).uppercased() + member.rawValue.dropFirst())
            return #"\#(start)\#(written)\b|\#(start)\#(name)(\.[a-z]+)?@|@\#(name)\b"#
        }.joined(separator: "|")
        let expression = try NSRegularExpression(pattern: pattern)
        var found: [String] = []

        for source in Self.sources {
            let directory = Self.iosDirectory.appendingPathComponent(source)
            let files = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil), source)
            for case let file as URL in files where ["swift", "json"].contains(file.pathExtension) {
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
                for (index, line) in lines.enumerated()
                where expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    found.append("\(source)/\(file.lastPathComponent):\(index + 1)")
                }
            }
        }

        XCTAssertEqual(found, [], "a real household member's name is drawn here")
    }

    #if DEBUG && canImport(UIKit)
    /// The family room's avatars, the account button and the onboarding draw a person's
    /// initial, so a made-up name starts with another letter than the real one.
    func testTheDemoHouseholdsPeopleHaveMadeUpNamesAndInitials() throws {
        let people = try XCTUnwrap(DemoRoom.participants.arrayValue).filter { $0["kind"]?.stringValue == "person" }
        XCTAssertEqual(people.compactMap { $0["id"]?.stringValue }, HouseholdMember.allCases.map(\.rawValue))

        for person in people {
            let id = try XCTUnwrap(person["id"]?.stringValue)
            let member = try XCTUnwrap(HouseholdMember(rawValue: id))
            let name = try XCTUnwrap(person["name"]?.stringValue)
            XCTAssertEqual(name, DemoRoom.memberName(member), "the room and the onboarding name \(id) alike")
            XCTAssertNotEqual(name.prefix(1).lowercased(), id.prefix(1).lowercased(), "\(name) has the real initial")
        }
    }
    #endif
}
