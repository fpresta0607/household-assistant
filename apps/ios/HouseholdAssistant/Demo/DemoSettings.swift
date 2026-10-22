#if DEBUG
// Corey's settings in the made-up household, kept the way the household-app plugin keeps
// them and answered in the shape its contract gives: Will's voice, GLM 5.3 Flash with its
// fallbacks, GPT Image 2.5 Flare for pictures and Veo 3.1 Fast for videos, the connectors
// his gateway has, this phone's notifications, OpenRouter's models of each kind, October's
// spend and a spoken sample. The names and numbers are the approved Settings page's.
// A change is applied and read back as the gateway would, so the demo
// and the screenshots show a change landing. Connectors come in the shape
// deploy/openclaw/plugins/household-app/connectors.js gives a phone that asks for the
// unavailable ones too: iCloud, Google and Notion start waiting for Franco's sign-in, the
// mail account is Gia's and so unavailable here, and a sign-in is linked, switched or
// forgotten as connect.js does it, listed by the account's name and never its secret.

import Foundation

@MainActor
final class DemoSettings {
    private var name = "Corey"
    private var voice = "will"
    private var tone = 64
    private var length = "balanced"
    private var model = "z-ai/glm-5.3-flash"
    private var fallbacks = ["z-ai/glm-5.3", "deepseek/deepseek-v4-flash-0731:free"]
    private var visionModel = "google/gemini-flash"
    private var imageModel = "openai/gpt-image-2.5-flare"
    private var videoModel = "google/veo-3.1-fast"
    private var connectorsOff: Set<String> = []
    /// The accounts each connector is signed in with, by its id.
    private var linked: [String: [Account]] = [:]
    private var notifications: [String: String] = [:]
    private let room: DemoRoom

    init(room: DemoRoom) {
        self.room = room
    }

    static let methods = [
        "household-app.settings",
        "household-app.settings.change",
        "household-app.connector.connect",
        "household-app.connector.disconnect",
        "household-app.models",
        "household-app.spend",
        "household-app.speak",
    ]

    /// The payload the plugin would answer `request` with, or nil for a method it lacks
    /// or a change it would refuse.
    func answer(_ request: GatewayRequest) -> JSONValue? {
        switch request.method {
        case "household-app.settings":
            return settings
        case "household-app.settings.change":
            return change(request.params)
        case "household-app.connector.connect", "household-app.connector.disconnect":
            return signIn(request)
        case "household-app.models":
            switch request.params["kind"]?.stringValue {
            case "vision":
                return .object(["models": .array(Self.visionModels.map(\.json))])
            case "image":
                return .object(["models": .array(Self.imageModels.map(\.json))])
            case "video":
                return .object(["models": .array(Self.videoModels.map(\.json))])
            default:
                return .object(["models": .array(Self.models.map(\.json))])
            }
        case "household-app.spend":
            return Self.spend
        case "household-app.speak":
            let seconds = UserDefaults.standard.bool(forKey: "StewardMessageSpeechDemo") ? 12 : 3
            let sample = room.keep(DemoMedia.voiceNote(seconds: seconds), kind: .voice, mime: "audio/wav", durationMs: seconds * 1_000)
            return .object(["media": .object([
                "id": .string(sample.id),
                "mime": .string(sample.mime),
                "bytes": .number(Double(sample.bytes)),
            ])])
        default:
            return nil
        }
    }

    // MARK: - The household

    private struct Model {
        let id: String
        let name: String
        let company: String
        let icon: String
        let input: Double
        let output: Double
        let badge: String?

        var choice: JSONValue {
            .object(["id": .string(id), "name": .string(name), "company": .string(company), "icon": .string(icon)])
        }

        var json: JSONValue {
            .object([
                "id": .string(id),
                "name": .string(name),
                "company": .string(company),
                "icon": .string(icon),
                "inputPerMillion": .number(input),
                "outputPerMillion": .number(output),
                "badge": badge.map(JSONValue.string) ?? .null,
            ])
        }
    }

    private static let models = [
        Model(id: "z-ai/glm-5.3-flash", name: "GLM 5.3 Flash", company: "Z.ai", icon: "zai", input: 0.1, output: 0.4, badge: "fast"),
        Model(id: "anthropic/claude-sonnet", name: "Claude Sonnet", company: "Anthropic", icon: "anthropic", input: 3, output: 15, badge: "smart"),
        Model(id: "openai/gpt-mini", name: "GPT mini", company: "OpenAI", icon: "openai", input: 0.25, output: 2, badge: "fast"),
        Model(id: "google/gemini-flash", name: "Gemini Flash", company: "Google", icon: "googlegemini", input: 0.3, output: 2.5, badge: "fast"),
        Model(id: "deepseek/deepseek-v4-flash-0731:free", name: "DeepSeek V4 Flash", company: "DeepSeek", icon: "deepseek", input: 0, output: 0, badge: "free"),
        Model(id: "z-ai/glm-5.3", name: "GLM 5.3", company: "Z.ai", icon: "zai", input: 0.45, output: 1.8, badge: nil),
        Model(id: "meta-llama/llama-4-maverick", name: "Llama 4 Maverick", company: "Meta", icon: "symbol:cpu", input: 0.15, output: 0.6, badge: nil),
    ]

    /// A model from OpenRouter's image or video list: its card by name and company, as
    /// Settings names the one in use, and in the list its price as OpenRouter listed it on
    /// 18 October 2026.
    private struct Choice {
        let id: String
        let name: String
        let company: String
        let icon: String
        let dollars: Double
        let per: String

        var card: JSONValue {
            .object(["id": .string(id), "name": .string(name), "company": .string(company), "icon": .string(icon)])
        }

        var json: JSONValue {
            .object([
                "id": .string(id),
                "name": .string(name),
                "company": .string(company),
                "icon": .string(icon),
                "price": .object(["dollars": .number(dollars), "per": .string(per)]),
            ])
        }
    }

    private static let visionModels = [
        Choice(id: "google/gemini-flash", name: "Gemini Flash", company: "Google", icon: "googlegemini", dollars: 0.3, per: "million input tokens"),
    ]

    private static let imageModels = [
        Choice(id: "openai/gpt-image-2.5-flare", name: "GPT Image 2.5 Flare", company: "OpenAI", icon: "openai", dollars: 30, per: "million image tokens"),
        Choice(id: "google/gemini-3.1-flash-image", name: "Nano Banana 2", company: "Google", icon: "googlegemini", dollars: 60, per: "million image tokens"),
        Choice(id: "black-forest-labs/flux-3-image", name: "FLUX 3 Image", company: "Black Forest Labs", icon: "blackforestlabs", dollars: 9.8204, per: "million image tokens"),
    ]

    private static let videoModels = [
        Choice(id: "google/veo-3.1-fast", name: "Veo 3.1 Fast", company: "Google", icon: "googlegemini", dollars: 0.1, per: "second at 720p"),
        Choice(id: "x-ai/grok-imagine-video-1.5", name: "Grok Imagine Video 1.5", company: "xAI", icon: "xai", dollars: 0.14, per: "second at 720p"),
        Choice(id: "bytedance/seedance-2.0-fast", name: "Seedance 2.0 Fast", company: "ByteDance", icon: "symbol:cpu", dollars: 4.2, per: "million video tokens"),
    ]

    private static let voices: [(id: String, name: String, summary: String)] = [
        ("will", "Will", "Young man, warm and easy"),
        ("jessica", "Jessica", "Young woman, bright and kind"),
        ("brian", "Brian", "Deep and steady"),
        ("alice", "Alice", "Clear and confident"),
        ("charlie", "Charlie", "Easygoing and friendly"),
    ]

    private struct ConnectorListing {
        let id: String
        let name: String
        let category: String
        let icon: String
        let summary: String
        /// How it signs in, nil when it needs no sign-in.
        var signInKind: String? = nil
        let capabilities: [String]
    }

    /// One account a connector is signed in with, as connect.js lists it.
    private struct Account {
        let id: String
        let name: String
        let email: String?
        let linkedAt: Date
        let abilities: [String]

        var json: JSONValue {
            .object([
                "id": .string(id),
                "name": .string(name),
                "email": email.map(JSONValue.string) ?? .null,
                "linkedAt": .number((linkedAt.timeIntervalSince1970 * 1000).rounded()),
                "status": .string("ok"),
                "abilities": .array(abilities.map(JSONValue.string)),
                "canDisconnect": .bool(true),
            ])
        }
    }

    /// Named as the approved page names them: SIQsermon and Scripture for faith, Search
    /// and Reading pages for the web. iCloud, Google and Notion sign in as connectors.js
    /// has them, by app password, Google's own sign-in and a pasted token until the
    /// household's Notion connection is set up, so ten are on until Franco signs in. The
    /// mail account is only on Gia's gateway, so Corey's never lists it.
    private static let connectors: [ConnectorListing] = [
        ConnectorListing(id: "pocket-piggies", name: "PocketPiggies", category: "money", icon: "pocketpiggies", summary: "Budgets, savings and the kids' allowances",
            capabilities: ["Reads your budgets, balances and spending", "Answers money questions in your own chat only"]),
        ConnectorListing(id: "siqsermon", name: "SIQsermon", category: "faith", icon: "siqsermon", summary: "Sermons and their notes",
            capabilities: ["Finds sermons and their notes", "Does word studies"]),
        ConnectorListing(id: "scripture", name: "Scripture", category: "faith", icon: "symbol:book", summary: "Berean Standard Bible",
            capabilities: ["Looks up any passage in the Berean Standard Bible"]),
        ConnectorListing(id: "icloud", name: "iCloud", category: "calendar-and-mail", icon: "icloud", summary: "The family calendar and reminders", signInKind: "password",
            capabilities: ["Reads your iCloud calendars", "Adds and changes events and reminders"]),
        ConnectorListing(id: "gog", name: "Google", category: "calendar-and-mail", icon: "google", summary: "Gmail and Google Calendar", signInKind: "oauth",
            capabilities: ["Reads your Gmail", "Reads and adds events in Google Calendar"]),
        ConnectorListing(id: "outlook", name: "Outlook", category: "calendar-and-mail", icon: "symbol:envelope", summary: "Work mail and its calendar",
            capabilities: ["Reads your Outlook mail", "Reads your Outlook calendar"]),
        ConnectorListing(id: "notion", name: "Notion", category: "notes", icon: "notion", summary: "Notes and shared pages", signInKind: "token",
            capabilities: ["Reads the Notion pages you share with it", "Adds and edits pages there when you ask"]),
        ConnectorListing(id: "perplexity", name: "Search", category: "web", icon: "perplexity", summary: "Searches the web, with sources",
            capabilities: ["Searches the web for current answers", "Says where each answer came from"]),
        ConnectorListing(id: "web-readability", name: "Reading pages", category: "web", icon: "symbol:doc.text.magnifyingglass", summary: "Reads a page you send",
            capabilities: ["Opens a link you send and reads the page"]),
        ConnectorListing(id: "images", name: "Pictures", category: "pictures-and-video", icon: "symbol:photo", summary: "Makes and edits pictures",
            capabilities: ["Makes a picture from a description", "Edits a picture you send"]),
        ConnectorListing(id: "videos", name: "Videos", category: "pictures-and-video", icon: "symbol:film", summary: "Makes short videos",
            capabilities: ["Makes a short video from a description"]),
        ConnectorListing(id: "weather", name: "Weather", category: "everyday", icon: "symbol:cloud.sun", summary: "Forecasts where you are",
            capabilities: ["Gives forecasts and current conditions"]),
        ConnectorListing(id: "diagrams", name: "Diagrams", category: "everyday", icon: "symbol:chart.bar.doc.horizontal", summary: "Draws plans and diagrams",
            capabilities: ["Draws plans, timelines and diagrams"]),
    ]

    /// How Google's page signs in, as google-connect.js describes it. The app keeps
    /// Google's own flow, so this only shows the shape.
    private static let googleOAuth: JSONValue = .object([
        "provider": .string("google"),
        "clientId": .string("123456789012-abc123def456.apps.googleusercontent.com"),
        "authorizeUrl": .string("https://accounts.google.com/o/oauth2/v2/auth"),
        "scopes": .array(OAuthAuthorization.googleScopes.map(JSONValue.string)),
        "redirectUri": .string("com.googleusercontent.apps.123456789012-abc123def456:/oauthredirect"),
        "usesPkce": .bool(true),
    ])

    /// October to the 15th as the box adds it up: $38.40 on the household's key, $24.10 of
    /// it Corey's, $11.85 Denise's and $2.45 the rest, and the total by the end of each day.
    private static let spentByDay = [2.31, 4.85, 6.20, 9.02, 11.14, 13.05, 16.62, 19.20, 20.71, 23.12, 26.30, 28.41, 31.67, 35.95, 38.40]

    private static let spend: JSONValue = .object([
        "month": .string("2026-10"),
        "at": .number(1_792_101_000_000),
        "total": .number(38.40),
        "days": .array(spentByDay.enumerated().map { index, spent in
            .object(["day": .string(String(format: "2026-10-%02d", index + 1)), "spent": .number(spent)])
        }),
        "lines": .array([
            .object(["id": .string("corey"), "name": .string("Corey"), "amount": .number(24.10)]),
            .object(["id": .string("denise"), "name": .string("Denise"), "amount": .number(11.85)]),
            .object(["id": .string("other"), "name": .string("Other use of the key"), "amount": .number(2.45)]),
        ]),
        "resetsOn": .string("2026-11-01"),
    ])

    private var settings: JSONValue {
        let inUse = Self.models.first { $0.id == model } ?? Self.models[0]
        return .object([
            "assistant": .object([
                "name": .string(name),
                "voice": .string(voice),
                "tone": .number(Double(tone)),
                "length": .string(length),
            ]),
            "voices": .array(Self.voices.map { voice in
                .object(["id": .string(voice.id), "name": .string(voice.name), "summary": .string(voice.summary)])
            }),
            "model": .object([
                "id": .string(inUse.id),
                "name": .string(inUse.name),
                "company": .string(inUse.company),
                "icon": .string(inUse.icon),
                "fallbacks": .array(fallbacks.compactMap { id in Self.models.first { $0.id == id }?.choice }),
            ]),
            "visionModel": Self.visionModels.first { $0.id == visionModel }?.card ?? .null,
            "imageModel": Self.imageModels.first { $0.id == imageModel }?.card ?? .null,
            "videoModel": Self.videoModels.first { $0.id == videoModel }?.card ?? .null,
            "connectors": .array(Self.connectors.map { view($0) }),
            "notifications": .object(notifications.mapValues(JSONValue.string)),
        ])
    }

    /// One connector as connectors.js shows it: `signIn` as the builds before read it,
    /// with no token sign-in among them, and the rest for this build.
    private func view(_ connector: ConnectorListing) -> JSONValue {
        let accounts = linked[connector.id] ?? []
        let signInKind = connector.signInKind
        let state: String
        if signInKind == nil || !accounts.isEmpty {
            state = "connected"
        } else {
            state = "available"
        }
        let olderSignIn: JSONValue = signInKind == "token" ? .null : signInKind.map(JSONValue.string) ?? .null
        let oauth: JSONValue = signInKind == "oauth" ? Self.googleOAuth : .null
        return .object([
            "id": .string(connector.id),
            "name": .string(connector.name),
            "category": .string(connector.category),
            "icon": .string(connector.icon),
            "summary": .string(connector.summary),
            "isOn": .bool(!connectorsOff.contains(connector.id)),
            "signIn": olderSignIn,
            "accounts": .number(Double(accounts.count)),
            "state": .string(state),
            "reason": .null,
            "capabilities": .array(connector.capabilities.map(JSONValue.string)),
            "signInKind": signInKind.map(JSONValue.string) ?? .null,
            "linkedAccounts": .array(accounts.map(\.json)),
            "oauth": oauth,
        ])
    }

    /// Applies a change the gateway would take, and reads the settings back.
    private func change(_ params: JSONValue) -> JSONValue? {
        guard let field = params["field"]?.stringValue, let value = params["value"]?.stringValue else {
            return nil
        }
        switch field {
        case "name" where AssistantName.isValid(value):
            name = value
        case "voice" where Self.voices.contains(where: { $0.id == value }):
            voice = value
        case "tone":
            guard let level = Int(value), (0...100).contains(level) else {
                return nil
            }
            tone = level
        case "length" where AnswerLength(rawValue: value) != nil:
            length = value
        case "model" where Self.models.contains(where: { $0.id == value }):
            model = value
            fallbacks.removeAll { $0 == value }
        case "model.fallback.1", "model.fallback.2":
            let position = field == "model.fallback.1" ? 0 : 1
            if value.isEmpty {
                if fallbacks.indices.contains(position) {
                    fallbacks.remove(at: position)
                }
            } else {
                guard Self.models.contains(where: { $0.id == value }), value != model,
                      !fallbacks.enumerated().contains(where: { $0.element == value && $0.offset != position }) else {
                    return nil
                }
                if fallbacks.indices.contains(position) {
                    fallbacks[position] = value
                } else {
                    fallbacks.append(value)
                }
            }
        case "model.vision" where Self.visionModels.contains(where: { $0.id == value }):
            visionModel = value
        case "model.image" where Self.imageModels.contains(where: { $0.id == value }):
            imageModel = value
        case "model.video" where Self.videoModels.contains(where: { $0.id == value }):
            videoModel = value
        case _ where field.hasPrefix("connector."):
            let id = String(field.dropFirst("connector.".count))
            guard Self.connectors.contains(where: { $0.id == id }), value == "on" || value == "off" else {
                return nil
            }
            if value == "on" {
                connectorsOff.remove(id)
            } else {
                connectorsOff.insert(id)
            }
        case _ where field.hasPrefix("notifications."):
            guard NotificationChoice(rawValue: value) != nil else {
                return nil
            }
            notifications[String(field.dropFirst("notifications.".count))] = value
        default:
            return nil
        }
        return settings
    }

    /// Links, switches or forgets an account as connect.js does, and reads the settings back
    /// with it listed: a connect links the connector's own account in the app and forgets
    /// the one it replaces, and a disconnect forgets the account it names, or the app's own.
    private func signIn(_ request: GatewayRequest) -> JSONValue? {
        guard
            let id = request.params["connector"]?.stringValue,
            let connector = Self.connectors.first(where: { $0.id == id && $0.signInKind != nil })
        else {
            return nil
        }
        let ownId = "\(id):app"
        var accounts = linked[id] ?? []
        if request.method == "household-app.connector.connect" {
            let forgotten = request.params["replacing"]?.stringValue
            accounts.removeAll { $0.id == ownId || $0.id == forgotten }
            accounts.insert(Self.account(for: connector, username: request.params["username"]?.stringValue), at: 0)
        } else {
            let forgotten = request.params["accountId"]?.stringValue ?? ownId
            accounts.removeAll { $0.id == forgotten }
        }
        linked[id] = accounts
        return settings
    }

    /// The account a sign-in from Franco's phone links: his own Google account, the iCloud
    /// address he typed, or the household's Notion workspace.
    private static func account(for connector: ConnectorListing, username: String?) -> Account {
        let now = Date()
        switch connector.id {
        case "gog":
            return Account(id: "gog:app", name: "Franco Marlowe", email: "franco@example.com", linkedAt: now, abilities: connector.capabilities)
        case "notion":
            return Account(
                id: "notion:app",
                name: "Marlowe Family",
                email: nil,
                linkedAt: now,
                abilities: ["Reads and edits the pages you share with it in Marlowe Family"]
            )
        default:
            return Account(id: "\(connector.id):app", name: username ?? connector.name, email: username, linkedAt: now, abilities: connector.capabilities)
        }
    }
}
#endif

