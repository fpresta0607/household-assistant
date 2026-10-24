#if DEBUG && canImport(UIKit)
import Foundation
import XCTest
@testable import HouseholdAssistant

@MainActor
final class DemoGatewayTests: XCTestCase {
    func testSendsStayOutOfHistoryUntilTheCueAndOrdinarySendsAreImmediate() async throws {
        for conversation in RoomConversation.allCases {
            for isControlled in [false, true] {
                // Arrange
                let control = "demo-send-" + UUID().uuidString
                let gateway = DemoGateway(sendControl: isControlled ? control : nil)
                defer { gateway.close() }
                try await gateway.open(XCTUnwrap(URL(string: "ws://demo.steward.invalid")))
                _ = try await gateway.receive()
                let message = try RoomOutgoing(
                    conversation: conversation, id: "sent-message", at: 1_700_000_000_000,
                    replyTo: nil, media: [], text: "On my way, see you at six", sign: { _ in "test-signature" }
                )
                let request = GatewayRequest(method: "household-app.send", params: message.params)

                // Act
                try await gateway.send(GatewayCodec.encode(request))
                if isControlled {
                    let history = GatewayRequest(method: "household-app.history", params: .object([
                        "conversation": .string(conversation.rawValue),
                    ]))
                    try await gateway.send(GatewayCodec.encode(history))
                    let response = try JSONDecoder().decode(JSONValue.self, from: Data(await gateway.receive().utf8))
                    XCTAssertEqual(response["id"]?.stringValue, history.id, "a send response escaped before the cue")
                    let messages = try XCTUnwrap(response["payload"]?["messages"]?.arrayValue)
                    XCTAssertFalse(messages.contains { $0["id"]?.stringValue == message.id }, "history exposed the pending send")
                    XCTAssertFalse(gateway.room.entries.contains { $0.id == message.id }, "the pending send was already stored")
                    CFNotificationCenterPostNotification(
                        CFNotificationCenterGetDarwinNotifyCenter(),
                        CFNotificationName((control + ".keep") as CFString), nil, nil, true
                    )
                    for _ in 0..<400 {
                        if gateway.room.entries.contains(where: { $0.id == message.id }) { break }
                        try await Task.sleep(for: .milliseconds(5))
                    }
                }

                // Assert
                let kept = try XCTUnwrap(gateway.room.entries.first { $0.id == message.id })
                XCTAssertEqual(kept.conversation, conversation)
                XCTAssertEqual(kept.text, message.text)
                XCTAssertEqual(gateway.room.entries.filter { $0.id == message.id }.count, 1)
                let response = try JSONDecoder().decode(JSONValue.self, from: Data(await gateway.receive().utf8))
                XCTAssertEqual(response["id"]?.stringValue, request.id)
                XCTAssertEqual(response["ok"]?.boolValue, true)
                XCTAssertEqual(response["payload"]?["entry"]?["id"]?.stringValue, message.id)
                let change = try JSONDecoder().decode(JSONValue.self, from: Data(await gateway.receive().utf8))
                XCTAssertEqual(change["event"]?.stringValue, "plugin.household-app.changed")
                XCTAssertEqual(change["payload"]?["rev"]?.intValue, kept.rev)
            }
        }
    }
}
#endif
