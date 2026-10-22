// An event built from its payload as JSON, the way the tests write one, and read exactly
// as the connection reads it off the socket: a chat or a room event comes out as its
// model, anything else keeps its JSON.

import Foundation
@testable import HouseholdAssistant

extension GatewayEvent {
    init(event: String, payload: JSONValue?, seq: Int?) {
        var frame: [String: JSONValue] = ["event": .string(event)]
        frame["payload"] = payload
        frame["seq"] = seq.map { JSONValue.number(Double($0)) }
        // A frame with a name always decodes as an event, at worst keeping its payload as JSON.
        self = try! JSONValue.object(frame).decoded(as: GatewayEvent.self)
    }
}
