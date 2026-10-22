#if DEBUG
// A made-up household, kept the way the household-app plugin keeps one: Franco and Gia,
// and their assistants Corey and Denise, in the family room and in Franco's own thread
// with Corey. The demo and the screenshot tests both show it, so the film and the
// pictures are of the same family. Every word and picture in it is invented here.
//
// It says what the approved mockups say, at the clock times they show whatever day it
// is drawn, so each screen can sit beside its mockup: dinner in the family room at 6:12
// PM, and in Franco's thread Monday's soccer schedule, last night's reminder and the
// permission slip he has not opened yet.
//
// It answers the plugin's methods with the payloads the plugin sends, built from one
// list of entries by revision, so whatever is added later arrives through `sync` like
// anything else would.

import CryptoKit
import Foundation

@MainActor
final class DemoRoom {
    struct Entry {
        var id: String
        var rev = 0
        var kind = "message"
        var conversation: RoomConversation
        var author: String
        var at: Int
        var text = ""
        var media: [RoomMedia] = []
        var replyTo: String?
        var messageId: String?
        var emoji: String?
        /// An approval card's approval, as the plugin keeps it on the card.
        var approval: JSONValue?
        /// How an approval card ended.
        var state: String?
        /// What an assistant's run changed, as the plugin keeps it on the reply.
        var did: [JSONValue] = []
        /// Where a person was, on a map they shared.
        var location: SharedLocation?
        /// A live map's newest move; nil on a move that stopped it.
        var position: LocationReport.Position?
        /// A person's answer to a reminder by place.
        var answer: String?
        /// A call's own fields, as the plugin keeps them on its entry.
        var call: [String: JSONValue] = [:]
        /// A change to the family room's look, as the plugin keeps it: what changed, and
        /// the color or the appearance it changed to.
        var look: [String: JSONValue] = [:]

        var json: JSONValue {
            var members: [String: JSONValue] = [
                "id": .string(id),
                "rev": .number(Double(rev)),
                "kind": .string(kind),
                "conversation": .string(conversation.rawValue),
                "author": .string(author),
                "at": .number(Double(at)),
                "origin": .string(author == DemoRoom.person || author == DemoRoom.assistant ? "local" : "peer"),
            ]
            if kind == "message" {
                members["text"] = .string(text)
                members["media"] = .array(media.map(\.json))
                members["replyTo"] = replyTo.map(JSONValue.string) ?? .null
                if let approval {
                    members["approval"] = approval
                }
                if !did.isEmpty {
                    members["did"] = .array(did)
                }
                if let location {
                    members["location"] = location.json
                }
            } else if kind == "live" {
                members["messageId"] = messageId.map(JSONValue.string) ?? .null
                members["position"] = position.map { position -> JSONValue in
                    .object([
                        "latitudeE6": .number(Double(position.latitudeE6)),
                        "longitudeE6": .number(Double(position.longitudeE6)),
                        "accuracy": .number(Double(position.accuracy)),
                        "at": .number(Double(position.at)),
                    ])
                } ?? .null
            } else if kind == "place" {
                members["messageId"] = messageId.map(JSONValue.string) ?? .null
                members["answer"] = answer.map(JSONValue.string) ?? .null
            } else if kind == "approval" {
                members["messageId"] = messageId.map(JSONValue.string) ?? .null
                members["state"] = state.map(JSONValue.string) ?? .null
            } else if kind == "call" {
                members.merge(call) { _, own in own }
            } else if kind == "look" {
                members.merge(look) { _, own in own }
            } else {
                members["messageId"] = messageId.map(JSONValue.string) ?? .null
                members["emoji"] = emoji.map(JSONValue.string) ?? .null
            }
            return .object(members)
        }
    }

    nonisolated static let person = "franco"
    nonisolated static let assistant = "corey"
    nonisolated static let sessionKeys: [RoomConversation: String] = [
        .family: "agent:main:household:group:family",
        .direct: "agent:main:household:direct:franco",
    ]
    nonisolated static let participants = everyone(faces: [:])

    private(set) var entries: [Entry] = []
    private(set) var media: [String: Data] = [:]
    /// The faces chosen so far, by participant, from photos `keep` was given, for a scene
    /// that shows them. Everyone shows their emoji or initial until then.
    var faces: [String: RoomMedia] = [:]
    private let now: () -> Date
    /// Corey and Denise on their direct line, which every page says the last move of.
    private let pair: DemoPair

    /// What Gia says in her voice note, which the demo and the screenshots show under it
    /// in place of a recognizer's hearing.
    static let voiceNoteWords = "Come home soon, the pasta is getting cold."
    /// How the family room's scene ends: Denise's answer, then Franco's, which Gia hearts.
    static let flightWords = "Gia's flight lands at 4:10. I put it on the family calendar \u{2708}\u{FE0F}"
    static let pickUpWords = "I'll pick you up. Text me when you land!"

    /// The photo, the voice note and the file the scene carries, to send again later.
    let photo: RoomMedia
    let voiceNote: RoomMedia
    let permissionSlip: RoomMedia
    /// The fewest messages a history page holds, whatever the phone asks for (DemoHeavyThread).
    var pageAtLeast = 0

    /// `isFinished` false leaves off how the family room's scene ends, for the film to play
    /// it and for the widgets, whose mockup is drawn just before it. `longThread` puts that
    /// many older messages in Franco's own thread first, for the hitch tests.
    init(now: @escaping () -> Date = Date.init, isFinished: Bool = true, longThread: Int = 0) {
        self.now = now
        // On the phone's own clock, so the family room's marker shows however the demo's
        // clock is set.
        pair = DemoPair(at: Date())
        let photoData = DemoMedia.photo()
        let voiceData = DemoMedia.voiceNote(seconds: 6)
        let slipData = DemoMedia.permissionSlip()
        photo = RoomMedia(id: Self.hash(photoData), kind: .photo, mime: "image/png", bytes: photoData.count, width: 900, height: 675)
        voiceNote = RoomMedia(
            id: Self.hash(voiceData),
            kind: .voice,
            mime: "audio/wav",
            bytes: voiceData.count,
            durationMs: 6_000,
            waveform: DemoMedia.waveform
        )
        permissionSlip = RoomMedia(
            id: Self.hash(slipData),
            kind: .file,
            mime: "application/pdf",
            bytes: slipData.count,
            name: "Field trip permission slip.pdf"
        )
        media = [photo.id: photoData, voiceNote.id: voiceData, permissionSlip.id: slipData]
        fillLongThread(longThread)
        stageTheScene()
        if isFinished {
            finishTheScene()
        }
    }

    var rev: Int {
        entries.last?.rev ?? 0
    }

    /// Keeps bytes the room can hand out from now on, named by their hash as the plugin
    /// names them, for a scene a test or the film adds.
    func keep(
        _ data: Data,
        kind: RoomMedia.Kind,
        mime: String,
        width: Int? = nil,
        height: Int? = nil,
        durationMs: Int? = nil,
        name: String? = nil
    ) -> RoomMedia {
        let kept = RoomMedia(
            id: Self.hash(data),
            kind: kind,
            mime: mime,
            bytes: data.count,
            durationMs: durationMs,
            width: width,
            height: height,
            name: name
        )
        media[kept.id] = data
        return kept
    }

    /// Adds an entry at the next revision and hands it back.
    @discardableResult
    func add(_ entry: Entry) -> Entry {
        var kept = entry
        kept.rev = rev + 1
        entries.append(kept)
        return kept
    }

    /// How many minutes before now the clock read `hour`:`minute`, `daysAgo` days back,
    /// for a message that should read as that time. Negative while that time is still to
    /// come today, which reads as "Today" all the same.
    func minutesAgo(at hour: Int, _ minute: Int, daysAgo: Int = 0) -> Double {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now())) ?? now()
        let moment = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        return now().timeIntervalSince(moment) / 60
    }

    /// A message, `minutesAgo` before now. `did` is what an assistant's run changed.
    @discardableResult
    func say(
        _ text: String,
        by author: String,
        in conversation: RoomConversation = .family,
        minutesAgo: Double = 0,
        media: [RoomMedia] = [],
        replyTo: String? = nil,
        did: [JSONValue] = []
    ) -> Entry {
        add(Entry(
            id: (author == Self.person ? (conversation == .family ? "m-" : "d-") : "a-") + UUID().uuidString.lowercased(),
            conversation: conversation,
            author: author,
            at: millis(minutesAgo: minutesAgo),
            text: text,
            media: media,
            replyTo: replyTo,
            did: did
        ))
    }

    /// One item of a reply's did list, as did.js in the plugin writes it: its time exact, in
    /// UTC with milliseconds.
    static func change(_ kind: String, _ change: String, title: String? = nil, at moment: Date? = nil) -> JSONValue {
        var members: [String: JSONValue] = ["kind": .string(kind), "change": .string(change)]
        if let title {
            members["title"] = .string(title)
        }
        if let moment {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            members["at"] = .string(formatter.string(from: moment))
        }
        return .object(members)
    }

    func react(to messageId: String, by author: String, with emoji: String?, in conversation: RoomConversation = .family) {
        add(Entry(
            id: "r-" + UUID().uuidString.lowercased(),
            kind: "reaction",
            conversation: conversation,
            author: author,
            at: millis(minutesAgo: 0),
            messageId: messageId,
            emoji: emoji
        ))
    }

    func read(_ messageId: String, by author: String, in conversation: RoomConversation = .family) {
        add(Entry(
            id: "read-" + UUID().uuidString.lowercased(),
            kind: "read",
            conversation: conversation,
            author: author,
            at: millis(minutesAgo: 0),
            messageId: messageId
        ))
    }

    /// A map `author` shared, `minutesAgo` before now, live until `until` or shared once.
    @discardableResult
    func shareMap(by author: String, at place: LocationReport.Position, until: Date?, in conversation: RoomConversation = .family, minutesAgo: Double = 0) -> Entry {
        add(Entry(
            id: (conversation == .family ? "m-" : "d-") + UUID().uuidString.lowercased(),
            conversation: conversation,
            author: author,
            at: millis(minutesAgo: minutesAgo),
            location: SharedLocation(position: place, until: until.map { Int(($0.timeIntervalSince1970 * 1000).rounded()) })
        ))
    }

    /// A live map moved to `place`, or stopped with nil, now.
    func moveMap(_ messageId: String, by author: String, to place: LocationReport.Position?) {
        guard let map = entries.first(where: { $0.id == messageId }) else {
            return
        }
        add(Entry(
            id: "live:" + messageId,
            kind: "live",
            conversation: map.conversation,
            author: author,
            at: millis(minutesAgo: 0),
            messageId: messageId,
            position: place
        ))
    }

    /// A person's yes or no to a reminder by place that would watch them.
    func answerPlace(_ messageId: String, by author: String, with answer: String) {
        add(Entry(
            id: "place:\(messageId):\(author)",
            kind: "place",
            conversation: .family,
            author: author,
            at: millis(minutesAgo: 0),
            messageId: messageId,
            answer: answer
        ))
    }

    /// A call with Corey that ended `minutesAgo` before now and lasted `seconds`, folded into
    /// one entry with its words, as the plugin keeps it once the phone ends the call.
    @discardableResult
    func call(lasting seconds: Int, minutesAgo: Double = 0, words: [(author: String, text: String)]) -> Entry {
        let ended = millis(minutesAgo: minutesAgo)
        let started = ended - seconds * 1000
        let lines = words.enumerated().map { index, line -> JSONValue in
            .object(["author": .string(line.author), "text": .string(line.text), "at": .number(Double(started + index * 4000))])
        }
        return add(Entry(
            id: "call:" + UUID().uuidString.lowercased(),
            kind: "call",
            conversation: .direct,
            author: Self.person,
            at: started,
            call: [
                "endedAt": .number(Double(ended)),
                "with": .string(Self.assistant),
                "turnIds": .array([]),
                "transcript": .array(lines),
                "isCut": .bool(false),
            ]
        ))
    }

    /// A step of Corey's run waiting for Franco's yes, as a card in his own thread.
    @discardableResult
    func askApproval(_ title: String, detail: String, isCommand: Bool = false) -> Entry {
        let approvalId = (isCommand ? "" : "plugin:") + UUID().uuidString.lowercased()
        return add(Entry(
            id: "ap-" + UUID().uuidString.lowercased(),
            conversation: .direct,
            author: Self.assistant,
            at: millis(minutesAgo: 0),
            text: "Needs your OK: \(title)\n\(detail)",
            approval: .object([
                "id": .string(approvalId),
                "kind": .string(isCommand ? "exec" : "plugin"),
                "title": .string(title),
                "detail": .string(detail),
                "decisions": .array([.string("allow-once"), .string("deny")]),
            ])
        ))
    }

    /// How an approval card ended, whoever answered it.
    func settleApproval(_ messageId: String, as state: String) {
        add(Entry(
            id: "approval:" + messageId,
            kind: "approval",
            conversation: .direct,
            author: Self.assistant,
            at: millis(minutesAgo: 0),
            messageId: messageId,
            state: state
        ))
    }

    /// The payload the plugin would answer `request` with, or nil for a method it lacks.
    func answer(_ request: GatewayRequest) -> JSONValue? {
        let params = request.params
        switch request.method {
        case "household-app.history":
            guard let conversation = params["conversation"]?.stringValue.flatMap(RoomConversation.init(rawValue:)) else {
                return nil
            }
            return history(conversation, before: params["before"]?.intValue, limit: params["limit"]?.intValue ?? 100)
        case "household-app.sync":
            return sync(since: params["since"]?.intValue ?? 0, limit: params["limit"]?.intValue ?? 500)
        case DemoPair.method:
            return pair.answer(params)
        case "household-app.media":
            return chunk(params["id"]?.stringValue ?? "", offset: params["offset"]?.intValue ?? 0, length: params["length"]?.intValue ?? 0)
        case "household-app.send":
            return send(params)
        case "household-app.react":
            if let messageId = params["messageId"]?.stringValue,
               let conversation = entries.first(where: { $0.id == messageId })?.conversation {
                react(to: messageId, by: Self.person, with: params["emoji"]?.stringValue, in: conversation)
            }
            return .object(["ok": .bool(true)])
        case "household-app.read", "household-app.typing", "household-app.push.register", "household-app.location":
            return .object(["ok": .bool(true)])
        case "household-app.location.live":
            guard let messageId = params["messageId"]?.stringValue else {
                return nil
            }
            moveMap(messageId, by: Self.person, to: params["position"].flatMap { try? $0.decoded(as: LocationReport.Position.self) })
            return .object(["entry": entries.last?.json ?? .null])
        case "household-app.place.answer":
            guard let messageId = params["messageId"]?.stringValue, let answer = params["answer"]?.stringValue else {
                return nil
            }
            answerPlace(messageId, by: Self.person, with: answer)
            return .object(["entry": entries.last?.json ?? .null])
        case "household-app.card.tick":
            return .object(["kept": .bool(true)])
        case "household-app.approval.answer":
            // OpenClaw takes Franco's answer at once, so the card ends the way he answered.
            guard let messageId = params["messageId"]?.stringValue, let decision = params["decision"]?.stringValue else {
                return nil
            }
            settleApproval(messageId, as: decision == "deny" ? "denied" : "approved")
            return .object(["answered": .bool(true)])
        case "household-app.look.set":
            return setLook(params)
        case "household-app.cart.ordered":
            guard
                let conversation = params["conversation"]?.stringValue.flatMap(RoomConversation.init(rawValue:)),
                let messageId = params["messageId"]?.stringValue
            else {
                return nil
            }
            return cartOrdered(messageId, in: conversation)
        default:
            return nil
        }
    }

    // MARK: - The scene

    /// Both conversations up to dinner. Franco has read the family room up to Corey's
    /// answer about the list, which leaves three new there, and his own thread up to
    /// Monday's, which leaves last night's reminder and the slip new.
    /// `count` older messages in Franco's own thread, one every 45 minutes up to two hours
    /// ago: his questions and Corey's answers, plain, with lists and in paragraphs, as a
    /// thread that has been used for weeks reads.
    private func fillLongThread(_ count: Int) {
        let questions = [
            "What's on this week?",
            "Can you move the dentist to Thursday?",
            "What do we need from the store?",
            "Remind me about the recital",
            "How long to Gia's office?",
        ]
        let answers = [
            "Here is the week:\n\n- **Monday** soccer at 5:45\n- **Tuesday** dentist at 3:30\n- **Thursday** recital at 6\n\nWant reminders for each?",
            "Done. The dentist is now Thursday at 3:30, and I told the office.",
            "From the list:\n\n1. Milk\n2. Eggs\n3. Bread\n4. Apples\n5. Coffee\n\nI can order them for Saturday morning.",
            "I will remind you at 5 the evening before, and again an hour ahead. The recital is at the school hall, and parking fills up early, so leave by 5:20.",
            "About 18 minutes now. Traffic is light on Maple Street, and there is a slowdown near the bridge that should clear by the time you leave.",
        ]
        for index in 0..<count {
            let isQuestion = index % 2 == 0
            let texts = isQuestion ? questions : answers
            say(
                texts[(index / 2) % texts.count],
                by: isQuestion ? Self.person : Self.assistant,
                in: .direct,
                minutesAgo: Double(count - index) * 45 + 120
            )
        }
    }

    private func stageTheScene() {
        let milk = say("Corey, can you add milk and eggs to the list?", by: "franco", minutesAgo: minutesAgo(at: 15, 5))
        let done = say("Done. Milk and eggs are on the shopping list \u{1F95B}\u{1F95A}", by: "corey", minutesAgo: minutesAgo(at: 15, 6))
        react(to: done.id, by: "franco", with: "\u{1F44D}")
        react(to: milk.id, by: "gia", with: "\u{2764}\u{FE0F}")
        read(done.id, by: "franco")
        // The photo and the voice note at the same moment, so the photo leads the strip on
        // Chats as it leads the room.
        let dinner = say("Dinner is ready \u{1F35D}", by: "gia", minutesAgo: minutesAgo(at: 18, 12), media: [photo])
        react(to: dinner.id, by: "franco", with: "\u{2764}\u{FE0F}")
        let voice = say("", by: "gia", minutesAgo: minutesAgo(at: 18, 12), media: [voiceNote])
        say("Leaving work now. Save me some!", by: "franco", minutesAgo: minutesAgo(at: 18, 13), replyTo: voice.id)

        // Monday, or the one before when this week's would read as today or yesterday.
        let weekday = Calendar.current.component(.weekday, from: now())
        let sinceMonday = (weekday + 5) % 7
        let monday = sinceMonday < 2 ? sinceMonday + 7 : sinceMonday
        say("Is the soccer schedule out?", by: "franco", in: .direct, minutesAgo: minutesAgo(at: 19, 5, daysAgo: monday))
        let schedule = say(
            "Yes. Games are Saturdays at 10 this fall \u{26BD}",
            by: "corey",
            in: .direct,
            minutesAgo: minutesAgo(at: 19, 5, daysAgo: monday)
        )
        read(schedule.id, by: "franco", in: .direct)
        say("Remind me to leave at 5:30", by: "franco", in: .direct, minutesAgo: minutesAgo(at: 21, 20, daysAgo: 1))
        say("Done. I will remind you at 5:30 PM \u{23F0}", by: "corey", in: .direct, minutesAgo: minutesAgo(at: 21, 20, daysAgo: 1))
        say("The school sent the field trip form. Can you find it?", by: "franco", in: .direct, minutesAgo: minutesAgo(at: 14, 48))
        say(
            "Here it is. It needs a signature by Friday.",
            by: "corey",
            in: .direct,
            minutesAgo: minutesAgo(at: 14, 50),
            media: [permissionSlip]
        )
    }

    /// The family room's last moments, as the mockup ends it: Denise puts Gia's flight on
    /// the calendar, Franco reads it and answers, and Gia hearts his answer and reads it.
    private func finishTheScene() {
        let flight = sayTheFlight(minutesAgo: minutesAgo(at: 18, 13))
        read(flight.id, by: "franco")
        let pickUp = say(Self.pickUpWords, by: "franco", minutesAgo: minutesAgo(at: 18, 14))
        react(to: pickUp.id, by: "gia", with: "\u{2764}\u{FE0F}")
        read(pickUp.id, by: "gia")
    }

    /// Denise's answer that ends the scene, with the chip for what her run did: Gia's
    /// landing on the family calendar, tomorrow at 4:10 PM.
    @discardableResult
    func sayTheFlight(minutesAgo: Double = 0) -> Entry {
        let calendar = Calendar.current
        let landing = calendar.date(byAdding: DateComponents(day: 1, hour: 16, minute: 10), to: calendar.startOfDay(for: now()))
        return say(Self.flightWords, by: "denise", minutesAgo: minutesAgo, did: [Self.change("event", "added", title: "Gia lands", at: landing)])
    }

    // MARK: - The cart

    /// Ordered on a cart card, answered the way the plugin answers it (cards.js,
    /// createCartOrdered): every item the card showed leaves the cart, the conversation gets
    /// the cart as it now stands, and Franco's own thread the order. Here that empties it.
    private func cartOrdered(_ messageId: String, in conversation: RoomConversation) -> JSONValue? {
        guard let card = entries.first(where: { $0.id == messageId && $0.conversation == conversation }) else {
            return nil
        }
        let shown = StewardCardParser.segments(in: card.text, isStreaming: false).compactMap { segment -> CartCard? in
            if case .card(let found) = segment, case .cart(let cart) = found.content {
                return cart
            }
            return nil
        }.last
        guard let shown, !shown.items.isEmpty else {
            return nil
        }
        let count = shown.items.count
        let said = count == 1 ? "Marked 1 item ordered." : "Marked \(count) items ordered."
        let cart = Self.block(#"{"type":"cart","id":"household","title":"Household cart","items":[],"skill":"lists"}"#)
        let order = Self.block(#"{"type":"order","title":"Household order","items":\#(count),"status":"ordered","steps":[{"label":"Ordered","at":"\#(Self.moment(now()))"},{"label":"Shipped"},{"label":"Out for delivery"},{"label":"Delivered"}],"skill":"lists"}"#)
        if conversation == .direct {
            say("\(said)\n\n\(order)\n\n\(cart)", by: Self.assistant, in: .direct)
        } else {
            say("\(said)\n\n\(cart)", by: Self.assistant, in: conversation)
            say("\(said)\n\n\(order)", by: Self.assistant, in: .direct)
        }
        return .object(["ordered": .number(Double(count))])
    }

    private static func block(_ json: String) -> String {
        "```steward-card\n\(json)\n```"
    }

    /// A moment with this phone's own offset, as the plugin writes one.
    private static func moment(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    // MARK: - Pages

    private func history(_ conversation: RoomConversation, before: Int?, limit: Int) -> JSONValue {
        let older = entries.filter { ($0.kind == "message" || $0.kind == "call") && $0.conversation == conversation && $0.rev < (before ?? .max) }
        let page = older.suffix(max(limit, pageAtLeast))
        var reactions: [String: JSONValue] = [:]
        for message in page {
            reactions[message.id] = .array(currentReactions(of: message.id))
        }
        var latestRead: [String: String] = [:]
        for entry in entries where entry.kind == "read" && entry.conversation == conversation {
            latestRead[entry.author] = entry.messageId
        }
        let cards = Set(page.filter { $0.approval != nil }.map(\.id))
        var approvals: [String: JSONValue] = [:]
        for entry in entries where entry.kind == "approval" {
            if let messageId = entry.messageId, cards.contains(messageId), let state = entry.state {
                approvals[messageId] = .string(state)
            }
        }
        let shown = Set(page.map(\.id))
        var lives: [String: JSONValue] = [:]
        var places: [String: [String: String]] = [:]
        for entry in entries where entry.messageId.map(shown.contains) == true {
            if entry.kind == "live", let messageId = entry.messageId {
                lives[messageId] = .object(["at": .number(Double(entry.at)), "position": entry.json["position"] ?? .null])
            } else if entry.kind == "place", let messageId = entry.messageId, let answer = entry.answer {
                places[messageId, default: [:]][entry.author] = answer
            }
        }
        return .object([
            "messages": .array(page.map(\.json)),
            "hasMore": .bool(older.count > page.count),
            "reactions": .object(reactions),
            "approvals": .object(approvals),
            "lives": .object(lives),
            "places": .object(places.mapValues { answers in
                .array(answers.sorted { $0.key < $1.key }.map { .object(["author": .string($0.key), "answer": .string($0.value)]) })
            }),
            "reads": .array(latestRead.sorted { $0.key < $1.key }.map { author, messageId in
                .object(["author": .string(author), "messageId": .string(messageId)])
            }),
            "participants": Self.everyone(faces: faces),
            "self": Self.selfJSON,
            "sessionKeys": Self.sessionKeysJSON,
            "looks": .array(looks(among: page, in: conversation, before: before, hasMore: older.count > page.count)),
            "familyLook": familyLook ?? .null,
            "pair": pair.mark,
        ])
    }

    /// The changes to the family room's look among a history page, as the plugin pages them:
    /// from the page's oldest message on, or from the start once nothing older is left.
    private func looks(among page: ArraySlice<Entry>, in conversation: RoomConversation, before: Int?, hasMore: Bool) -> [JSONValue] {
        let from = hasMore ? page.first?.rev ?? 0 : 0
        let upTo = before ?? .max
        return entries.filter { $0.kind == "look" && $0.conversation == conversation && $0.rev >= from && $0.rev < upTo }.map(\.json)
    }

    /// The family room's look, each part as its newest change left it (family-look.js).
    private var familyLook: JSONValue? {
        let looks = entries.filter { $0.kind == "look" }.sorted { $0.at < $1.at }
        guard !looks.isEmpty else {
            return nil
        }
        var ring: JSONValue = .null
        var appearance: JSONValue = .string("auto")
        var background: JSONValue = .null
        for entry in looks {
            switch entry.look["change"]?.stringValue {
            case "color":
                ring = entry.look["ring"] ?? .null
            case "appearance":
                appearance = entry.look["appearance"] ?? appearance
                if let chosen = entry.look["background"], chosen != .null {
                    background = chosen
                }
            default:
                break
            }
        }
        return .object(["ring": ring, "appearance": appearance, "background": background])
    }

    /// Franco's change to the family room's color or appearance, as the plugin keeps it.
    private func setLook(_ params: JSONValue) -> JSONValue? {
        guard let change = params["change"]?.stringValue, change == "color" || change == "appearance" else {
            return nil
        }
        var look: [String: JSONValue] = ["change": .string(change)]
        for key in ["ring", "appearance", "background"] {
            if let value = params[key] {
                look[key] = value
            }
        }
        let at = millis(minutesAgo: 0)
        _ = add(Entry(id: "look:\(Self.person):\(at)", kind: "look", conversation: .family, author: Self.person, at: at, look: look))
        return .object(["familyLook": familyLook ?? .null])
    }

    private func sync(since: Int, limit: Int) -> JSONValue {
        let newer = entries.filter { $0.rev > since }
        let page = newer.prefix(limit)
        return .object([
            "entries": .array(page.map(\.json)),
            "rev": .number(Double(page.last?.rev ?? max(since, rev))),
            "hasMore": .bool(newer.count > page.count),
            "participants": Self.everyone(faces: faces),
            "self": Self.selfJSON,
            "sessionKeys": Self.sessionKeysJSON,
            "peerAssistant": Self.peerAssistant,
            "familyLook": familyLook ?? .null,
            "pair": pair.mark,
        ])
    }

    /// Denise, as Gia's gateway carries her across the relay for her page in the family room.
    private static let peerAssistant: JSONValue = .object([
        "name": .string("Denise"),
        "voiceName": .string("Jessica"),
        "voice": .string("jessica"),
        "modelName": .string("GLM 5.3 Flash"),
        "familyRoom": .string("Answers when named"),
    ])

    private func chunk(_ id: String, offset: Int, length: Int) -> JSONValue? {
        guard let data = media[id], offset >= 0, offset <= data.count else {
            return nil
        }
        let end = min(offset + max(length, 0), data.count)
        return .object([
            "data": .string(data.subdata(in: offset..<end).base64EncodedString()),
            "offset": .number(Double(offset)),
            "total": .number(Double(data.count)),
        ])
    }

    private func send(_ params: JSONValue) -> JSONValue? {
        guard
            let conversation = params["conversation"]?.stringValue.flatMap(RoomConversation.init(rawValue:)),
            let id = params["id"]?.stringValue
        else {
            return nil
        }
        let sentMedia = (params["media"]?.arrayValue ?? []).compactMap { try? $0.decoded(as: RoomMedia.self) }
        let entry = add(Entry(
            id: id,
            conversation: conversation,
            author: Self.person,
            at: params["at"]?.intValue ?? millis(minutesAgo: 0),
            text: params["text"]?.stringValue ?? "",
            media: sentMedia,
            replyTo: params["replyTo"]?.stringValue,
            location: params["location"].flatMap { try? $0.decoded(as: SharedLocation.self) }
        ))
        return .object(["entry": entry.json])
    }

    private func currentReactions(of messageId: String) -> [JSONValue] {
        var byAuthor: [String: String] = [:]
        for entry in entries where entry.kind == "reaction" && entry.messageId == messageId {
            byAuthor[entry.author] = entry.emoji
        }
        return byAuthor.sorted { $0.key < $1.key }.map { author, emoji in
            .object(["author": .string(author), "emoji": .string(emoji)])
        }
    }

    private func millis(minutesAgo: Double) -> Int {
        Int(((now().timeIntervalSince1970 - minutesAgo * 60) * 1000).rounded())
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let selfJSON: JSONValue = .object(["person": .string(person), "assistant": .string(assistant)])

    private static var sessionKeysJSON: JSONValue {
        .object(Dictionary(uniqueKeysWithValues: sessionKeys.map { ($0.key.rawValue, JSONValue.string($0.value)) }))
    }

    /// Everyone in the room, as the plugin lists them, each with their face if one is chosen.
    nonisolated private static func everyone(faces: [String: RoomMedia]) -> JSONValue {
        .array([
            participant("franco", "Franco", kind: "person", isOwner: true, face: faces["franco"]),
            participant("gia", "Gia", kind: "person", face: faces["gia"]),
            participant("corey", "Corey", kind: "assistant", emoji: "\u{1F989}", face: faces["corey"]),
            participant("denise", "Denise", kind: "assistant", emoji: "\u{1F338}", face: faces["denise"]),
        ])
    }

    nonisolated private static func participant(
        _ id: String,
        _ name: String,
        kind: String,
        isOwner: Bool = false,
        emoji: String? = nil,
        face: RoomMedia?
    ) -> JSONValue {
        var members: [String: JSONValue] = [
            "id": .string(id),
            "name": .string(name),
            "kind": .string(kind),
            "isOwner": .bool(isOwner),
        ]
        if let emoji {
            members["emoji"] = .string(emoji)
        }
        if let face {
            members["avatar"] = face.json
        }
        return .object(members)
    }
}
#endif
