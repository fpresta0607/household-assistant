// Loads the frames captured from the live gateway.
//
// The fixtures are found relative to this source file rather than through a
// bundle: that works unchanged under `swift test` on Linux and under
// `xcodebuild test` on the simulator, which shares the Mac's file system, and
// it keeps the fixtures out of the shipped app.

import Foundation
import XCTest

enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("HouseholdAssistant/Protocol/Fixtures")

    static func text(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name + ".json"), encoding: .utf8)
    }

    /// A face a gateway gives a participant, in place of the Telegram photos Corey's and
    /// Denise's gateways start them with: an owl and a blossom, drawn as plain shapes for
    /// these fixtures, so no photo of the household's is in a picture of the app.
    static func face(_ participant: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent("faces/\(participant).jpg"))
    }

    static func allNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .sorted()
    }

    /// The fixture with its `id` replaced, so a captured response answers a live request.
    static func text(_ name: String, answering requestId: String) throws -> String {
        try text(name, answering: requestId) { _ in }
    }

    /// The same, after `edit` has changed the frame: a scope the gateway did
    /// not grant that day, a skill it does not pin, a list with nothing in it.
    static func text(
        _ name: String,
        answering requestId: String,
        editing edit: (inout [String: Any]) -> Void
    ) throws -> String {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try text(name).utf8)) as? [String: Any]
        )
        object["id"] = requestId
        edit(&object)
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
