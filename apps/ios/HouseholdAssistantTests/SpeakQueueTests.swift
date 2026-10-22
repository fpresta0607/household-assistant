// Talk's voice: each sentence of the reply spoken by the gateway, played in order with no
// gap, the next one fetched while the one before it plays, and a refusal over today's
// ceiling told apart from any other failure.

import XCTest
@testable import HouseholdAssistant

final class SpeakQueueTests: XCTestCase {
    func testTheFirstSentenceAndTheNextAreFetchedAtOnce() {
        var queue = SpeakQueue()
        XCTAssertEqual(queue.add(["Standup at 9.", "Then lunch with Rosa.", "Then the dentist."]), [
            .fetch(id: 0, text: "Standup at 9."),
            .fetch(id: 1, text: "Then lunch with Rosa."),
        ])
    }

    func testSentencesStreamingInAreFetchedOnlyOneAhead() {
        var queue = SpeakQueue()
        XCTAssertEqual(queue.add(["Standup at 9."]), [.fetch(id: 0, text: "Standup at 9.")])
        XCTAssertEqual(queue.add(["Then lunch."]), [.fetch(id: 1, text: "Then lunch.")])
        XCTAssertEqual(queue.add(["Then the dentist."]), [], "the third waits until the first has been said")
    }

    func testTheFirstPlaysAsSoonAsItsAudioIsIn() {
        var queue = SpeakQueue()
        _ = queue.add(["Standup at 9.", "Then lunch."])
        XCTAssertNil(queue.playing)
        XCTAssertEqual(queue.arrived(0), [.play(id: 0)])
        XCTAssertEqual(queue.playing, 0)
    }

    func testTheNextIsFetchedWhileTheCurrentPlaysAndFollowsItWithNoGap() {
        var queue = SpeakQueue()
        _ = queue.add(["Standup at 9.", "Then lunch.", "Then the dentist."])
        _ = queue.arrived(0)
        XCTAssertEqual(queue.arrived(1), [], "the second waits for the first to end")
        XCTAssertEqual(queue.finished(0), [.play(id: 1), .fetch(id: 2, text: "Then the dentist.")])
    }

    func testTheyPlayInOrderWhicheverAudioArrivesFirst() {
        var queue = SpeakQueue()
        _ = queue.add(["Standup at 9.", "Then lunch."])
        XCTAssertEqual(queue.arrived(1), [])
        XCTAssertNil(queue.playing)
        XCTAssertEqual(queue.arrived(0), [.play(id: 0)])
        XCTAssertEqual(queue.finished(0), [.play(id: 1)])
        XCTAssertEqual(queue.finished(1), [])
        XCTAssertTrue(queue.isEmpty)
    }

    func testAnEndWaitsForTheNextAudioWhenItIsLate() {
        var queue = SpeakQueue()
        _ = queue.add(["Standup at 9.", "Then lunch."])
        _ = queue.arrived(0)
        XCTAssertEqual(queue.finished(0), [])
        XCTAssertNil(queue.playing)
        XCTAssertEqual(queue.arrived(1), [.play(id: 1)])
    }

    func testOnlyTheOnePlayingCanEnd() {
        var queue = SpeakQueue()
        _ = queue.add(["Standup at 9.", "Then lunch."])
        _ = queue.arrived(0)
        XCTAssertEqual(queue.finished(1), [])
        XCTAssertEqual(queue.playing, 0)
    }

    /// A tap stops the voice, and the next reply starts afresh.
    func testStoppingForgetsEverythingAndALateArrivalIsIgnored() {
        var queue = SpeakQueue()
        _ = queue.add(["Standup at 9.", "Then lunch."])
        _ = queue.arrived(0)
        queue.stop()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.playing)
        XCTAssertEqual(queue.arrived(1), [], "audio asked for before the stop plays nothing")
        XCTAssertEqual(queue.finished(0), [])
        XCTAssertEqual(
            queue.add(["Which recital?"]),
            [.fetch(id: 2, text: "Which recital?")],
            "a sentence after a stop never shares a number with one before it"
        )
    }

    // MARK: - Today's ceiling

    func testOnlyTheGatewaysLimitMeansTodaysVoiceIsUsedUp() {
        let limit = GatewayErrorShape(code: "LIMIT", message: "Talk has reached today's limit.", details: nil)
        let unavailable = GatewayErrorShape(code: "UNAVAILABLE", message: "the household app could not do that", details: nil)
        XCTAssertTrue(SpeakQueue.isUsedUp(limit))
        XCTAssertFalse(SpeakQueue.isUsedUp(unavailable))
        XCTAssertFalse(SpeakQueue.isUsedUp(GatewayConnectionError.timedOut))
    }

    /// Through a connection: the gateway answers with the audio to read like a voice note,
    /// in the assistant's own voice when none is named, and refuses over the ceiling.
    @MainActor
    func testTheGatewaySpeaksASentenceOrRefusesOverTheCeiling() async throws {
        let hash = String(repeating: "ab", count: 32)
        let transport = ScriptedTransport()
        var asked: [JSONValue] = []
        transport.onOpen = { $0.push((try? Fixtures.text("connect-challenge")) ?? "") }
        transport.onRequest = { transport, request in
            switch request.method {
            case "connect":
                transport.push((try? Fixtures.text("hello-ok-device-token", answering: request.id)) ?? "")
            case "household-app.speak" where request.params["text"]?.stringValue == "Over the ceiling.":
                transport.push(#"{"type":"res","id":"\#(request.id)","ok":false,"error":{"code":"LIMIT","message":"Talk has reached today's limit."}}"#)
            case "household-app.speak":
                asked.append(request.params)
                transport.push(#"{"type":"res","id":"\#(request.id)","ok":true,"payload":{"media":{"id":"\#(hash)","mime":"audio/mpeg","bytes":5120}}}"#)
            default:
                break
            }
        }
        let connection = GatewayConnection(
            transport: transport,
            credentials: MemoryCredentialStore(deviceToken: StoredDeviceToken(token: "t")),
            signer: DeviceSigner(deviceId: "device-1", publicKey: "public-key") { _ in "signature" }
        ) { _ in
            await Task.yield()
        }
        connection.start(GatewayConnection.Configuration(
            url: try XCTUnwrap(URL(string: "ws://127.0.0.1:18800")),
            client: .stewardPhone(displayName: "test", version: "0.1.0"),
            scopes: OperatorScope.chat,
            locale: "en-US"
        ))
        var attemptsLeft = 400
        while attemptsLeft > 0, connection.state != .connected {
            try await Task.sleep(for: .milliseconds(5))
            attemptsLeft -= 1
        }
        XCTAssertEqual(connection.state, .connected)

        let media = try await connection.speak("Standup at 9.", voice: nil)
        XCTAssertEqual(media, RoomMedia(id: hash, kind: .voice, mime: "audio/mpeg", bytes: 5120))
        XCTAssertEqual(asked, [.object(["text": .string("Standup at 9.")])], "no voice named: the assistant's own")

        do {
            _ = try await connection.speak("Over the ceiling.", voice: nil)
            XCTFail("expected the gateway's refusal")
        } catch {
            XCTAssertTrue(SpeakQueue.isUsedUp(error))
        }
        connection.stop()
    }
}
