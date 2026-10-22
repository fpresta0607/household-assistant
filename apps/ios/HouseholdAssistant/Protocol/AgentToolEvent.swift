// One step of a tool an assistant's run uses: an `agent` event on the run's `tool`
// stream, which starts, may update, and ends with a result.
//
// The gateway sends a channel run's steps only to a connection that follows the run's
// session; see `followSession`. Of the tool's arguments only a shell command is read,
// and only to tell which of the box's skills it runs.

import Foundation

struct AgentToolEvent: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case start, update, result
        /// A phase a later gateway adds.
        case unknown
    }

    let sessionKey: String
    /// The run the step belongs to, so each run's steps are told apart.
    let runId: String?
    let phase: Phase
    let name: String
    let toolCallId: String?
    let command: String?

    /// Nil for any other event.
    init?(_ event: GatewayEvent) {
        guard
            event.event == "agent",
            let payload = event.payload,
            payload["stream"]?.stringValue == "tool",
            let sessionKey = payload["sessionKey"]?.stringValue,
            let data = payload["data"],
            let name = data["name"]?.stringValue
        else {
            return nil
        }
        self.sessionKey = sessionKey
        runId = payload["runId"]?.stringValue
        switch data["phase"]?.stringValue {
        case "start": phase = .start
        case "update": phase = .update
        case "result": phase = .result
        default: phase = .unknown
        }
        self.name = name
        toolCallId = data["toolCallId"]?.stringValue
        command = data["args"]?["command"]?.stringValue
    }
}
