// Photos, voice notes, videos and files read from the gateway in chunks, once each, into
// a cache on the phone.

import XCTest
@testable import HouseholdAssistant

@MainActor
final class RoomMediaCacheTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("room-media-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func connected(serving bytes: Data, id: String) async -> (GatewayConnection, ScriptedTransport) {
        let transport = ScriptedTransport()
        let store = MemoryCredentialStore(deviceToken: StoredDeviceToken(token: "t"))
        let connection = GatewayConnection(
            transport: transport,
            credentials: store,
            signer: DeviceSigner(deviceId: "device-1", publicKey: "public-key") { _ in "signature" }
        ) { _ in
            await Task.yield()
        }
        transport.onOpen = { $0.push((try? Fixtures.text("connect-challenge")) ?? "") }
        transport.onRequest = { transport, request in
            switch request.method {
            case "connect":
                transport.push((try? Fixtures.text("hello-ok-device-token", answering: request.id)) ?? "")
            case "household-app.media":
                let offset = request.params["offset"]?.intValue ?? 0
                let length = request.params["length"]?.intValue ?? 0
                let slice = request.params["id"]?.stringValue == id
                    ? bytes.subdata(in: min(offset, bytes.count)..<min(offset + length, bytes.count))
                    : Data()
                transport.push(#"{"type":"res","id":"\#(request.id)","ok":true,"payload":{"data":"\#(slice.base64EncodedString())","offset":\#(offset),"total":\#(bytes.count)}}"#)
            default:
                break
            }
        }
        connection.start(GatewayConnection.Configuration(
            url: URL(string: "ws://127.0.0.1:18800")!,
            client: .stewardPhone(displayName: "test", version: "0.1.0"),
            scopes: OperatorScope.chat,
            locale: "en-US"
        ))
        var attemptsLeft = 400
        while attemptsLeft > 0, connection.state != .connected {
            try? await Task.sleep(for: .milliseconds(5))
            attemptsLeft -= 1
        }
        return (connection, transport)
    }

    func testAFileIsReadInChunksAndKeptUnderItsHashWithItsExtension() async throws {
        let bytes = Data((0..<(GatewayConnection.roomChunkBytes + 100)).map { UInt8($0 % 251) })
        let id = String(repeating: "a", count: 64)
        let (connection, transport) = await connected(serving: bytes, id: id)
        let cache = RoomMediaCache(connection: connection, directory: directory)
        let media = RoomMedia(id: id, kind: .voice, mime: "audio/mp4", bytes: bytes.count)

        let url = try await cache.url(for: media)

        XCTAssertEqual(url.lastPathComponent, "\(id).m4a")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(transport.requests.filter { $0.method == "household-app.media" }.count, 2)
        XCTAssertEqual(cache.cachedURL(for: media), url)
    }

    func testAFileAlreadyKeptIsNotReadAgain() async throws {
        let bytes = Data(repeating: 9, count: 10)
        let id = String(repeating: "b", count: 64)
        let (connection, transport) = await connected(serving: bytes, id: id)
        let cache = RoomMediaCache(connection: connection, directory: directory)
        let media = RoomMedia(id: id, kind: .photo, mime: "image/jpeg", bytes: 10)
        _ = try await cache.url(for: media)
        _ = try await cache.url(for: media)
        XCTAssertEqual(transport.requests.filter { $0.method == "household-app.media" }.count, 1)
    }

    func testTwoScreensAskingAtOnceShareOneRead() async throws {
        let bytes = Data(repeating: 3, count: 10)
        let id = String(repeating: "c", count: 64)
        let (connection, transport) = await connected(serving: bytes, id: id)
        let cache = RoomMediaCache(connection: connection, directory: directory)
        let media = RoomMedia(id: id, kind: .video, mime: "video/mp4", bytes: 10)
        async let first = cache.url(for: media)
        async let second = cache.url(for: media)
        let urls = try await [first, second]
        XCTAssertEqual(urls[0], urls[1])
        XCTAssertEqual(urls[0].pathExtension, "mp4")
        XCTAssertEqual(transport.requests.filter { $0.method == "household-app.media" }.count, 1)
    }

    func testAFileThatComesBackTheWrongSizeIsNotKept() async throws {
        let id = String(repeating: "d", count: 64)
        let (connection, _) = await connected(serving: Data(repeating: 1, count: 5), id: id)
        let cache = RoomMediaCache(connection: connection, directory: directory)
        let media = RoomMedia(id: id, kind: .file, mime: "application/pdf", bytes: 10)
        do {
            _ = try await cache.url(for: media)
            XCTFail("a short file was kept")
        } catch {
            XCTAssertNil(cache.cachedURL(for: media))
        }
    }

    func testAnIdThatIsNotAHashIsNeverAPath() async throws {
        let (connection, _) = await connected(serving: Data(), id: "x")
        let cache = RoomMediaCache(connection: connection, directory: directory)
        let media = RoomMedia(id: "../../secrets", kind: .file, mime: "application/pdf", bytes: 1)
        do {
            _ = try await cache.url(for: media)
            XCTFail("a path was accepted as an id")
        } catch {
            XCTAssertNil(cache.cachedURL(for: media))
        }
    }

    func testEachKindGetsTheExtensionItsPlayerExpects() {
        XCTAssertEqual(RoomMediaCache.fileExtension(for: "audio/mp4"), "m4a")
        XCTAssertEqual(RoomMediaCache.fileExtension(for: "audio/ogg"), "ogg")
        XCTAssertEqual(RoomMediaCache.fileExtension(for: "audio/mpeg"), "mp3")
        XCTAssertEqual(RoomMediaCache.fileExtension(for: "image/jpeg"), "jpg")
        XCTAssertEqual(RoomMediaCache.fileExtension(for: "image/png"), "png")
        XCTAssertEqual(RoomMediaCache.fileExtension(for: "video/quicktime"), "mov")
        XCTAssertEqual(RoomMediaCache.fileExtension(for: "application/pdf"), "pdf")
        XCTAssertEqual(RoomMediaCache.fileExtension(for: "application/x-unknown"), "bin")
    }
}
