// The household-app plugin's settings methods, typed: this phone's own assistant, the
// models it can answer and make pictures and videos with, this month's spend, and a
// sample spoken by the gateway.
// `settings`, `models` and `spend` need `operator.read`, `settings.change`, a connector's
// `connect` and `disconnect` and `speak` need `operator.write`. The phone holds both.
//
// The gateway lists only the connectors it has. Earlier builds asked for the ones it cannot
// have too, with `include: ["unavailable"]`, and showed them dimmed, such as Gia's Email on
// Franco's phone, a list of what was never his to turn on.

import Foundation

extension GatewayConnection {
    func assistantSettings() async throws -> AssistantSettings {
        try await request("household-app.settings", as: AssistantSettings.self)
    }

    /// The gateway checks `signature` against its own person's paired phones, writes the
    /// change, and answers with the settings read back from its config.
    func changeSetting(_ change: SettingsChange, signature: String) async throws -> AssistantSettings {
        try await request("household-app.settings.change", change.params(signature: signature), as: AssistantSettings.self)
    }

    /// A connector's sign-in or sign-out, signed as a settings change is. The gateway
    /// answers with the settings read back, each connector's accounts listed again.
    func changeConnector(_ change: ConnectorChange, signature: String) async throws -> AssistantSettings {
        try await request(change.method, change.params(signature: signature), as: AssistantSettings.self)
    }

    func openRouterModels() async throws -> [OpenRouterModel] {
        guard let models = try await request("household-app.models")["models"] else {
            throw GatewayConnectionError.unexpectedFrame
        }
        return try models.decoded(as: [OpenRouterModel].self)
    }

    /// OpenRouter's models of one kind by name, company, icon and price, as the Image and
    /// Video segments list them. The video list may be empty.
    func modelChoices(_ kind: ModelKind) async throws -> [MediaModel] {
        guard let models = try await request("household-app.models", .object(["kind": .string(kind.rawValue)]))["models"] else {
            throw GatewayConnectionError.unexpectedFrame
        }
        return try models.decoded(as: [MediaModel].self)
    }

    /// The household's month as the box last added it up, the same on both gateways.
    func spend() async throws -> SpendReport {
        try await request("household-app.spend", as: SpendReport.self)
    }

    /// `text` spoken by the gateway in `voice`, or in the assistant's own voice when nil,
    /// kept with the room's media and read like a voice note. Counts against Talk's daily
    /// ceiling, which refuses with code `LIMIT` and a plain sentence.
    func speak(_ text: String, voice: String?) async throws -> RoomMedia {
        var params: [String: JSONValue] = ["text": .string(text)]
        if let voice {
            params["voice"] = .string(voice)
        }
        let media = try await request("household-app.speak", .object(params))["media"]
        guard let id = media?["id"]?.stringValue, let mime = media?["mime"]?.stringValue, let bytes = media?["bytes"]?.intValue else {
            throw GatewayConnectionError.unexpectedFrame
        }
        return RoomMedia(id: id, kind: .voice, mime: mime, bytes: bytes)
    }
}
