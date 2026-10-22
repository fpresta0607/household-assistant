#if DEBUG
// Leo's iPhones in the made-up household, as Corey's gateway lists them for Account
// and as the approved Settings page shows them: this iPhone, and his iPad Air seen
// yesterday. A removal and a setup code are answered in the shape the household-app
// plugin's contract gives them, and a removal is applied, so the demo and the
// screenshots show it landing.

import Foundation

@MainActor
final class DemoPhones {
    private struct Phone {
        let id: String
        let name: String
        let model: String
        let seenAgo: TimeInterval
        let isThisPhone: Bool
    }

    private var phones = [
        Phone(id: "franco-iphone", name: "Steward AI on iPhone", model: "iphone", seenAgo: 0, isThisPhone: true),
        Phone(id: "franco-ipad", name: "iPad Air", model: "ipad", seenAgo: 26 * 3600, isThisPhone: false),
    ]

    static let methods = [
        "household-app.phones",
        "household-app.phones.remove",
        "household-app.pair.code",
    ]

    /// The payload the plugin would answer `request` with, or nil for a method it lacks
    /// or a removal it would refuse.
    func answer(_ request: GatewayRequest) -> JSONValue? {
        switch request.method {
        case "household-app.phones":
            return list
        case "household-app.phones.remove":
            guard
                let device = request.params["device"]?.stringValue,
                phones.contains(where: { $0.id == device && !$0.isThisPhone })
            else {
                return nil
            }
            phones.removeAll { $0.id == device }
            return list
        case "household-app.pair.code":
            return code
        default:
            return nil
        }
    }

    private var list: JSONValue {
        let now = Date().timeIntervalSince1970
        return .object(["phones": .array(phones.map { phone in
            .object([
                "id": .string(phone.id),
                "name": .string(phone.name),
                "model": .string(phone.model),
                "lastSeenAtMs": .number(((now - phone.seenAgo) * 1000).rounded()),
                "isThisPhone": .bool(phone.isThisPhone),
            ])
        })])
    }

    /// A code in the shape OpenClaw's setup code has, for a gateway that does not exist.
    private var code: JSONValue {
        let expiresAtMs = ((Date().timeIntervalSince1970 + 600) * 1000).rounded()
        let fields: JSONValue = .object([
            "url": .string("wss://demo.steward.invalid"),
            "bootstrapToken": .string("demo-single-use"),
            "expiresAtMs": .number(expiresAtMs),
            "access": .string("limited"),
            "person": .string(DemoRoom.person),
            "assistant": .string("Corey"),
        ])
        let setupCode = Base64URL.encode((try? JSONEncoder().encode(fields)) ?? Data())
        return .object([
            "setupCode": .string(setupCode),
            "link": .string("https://demo.steward.invalid/household-app/pair#\(setupCode)"),
            "expiresAtMs": .number(expiresAtMs),
        ])
    }
}
#endif
