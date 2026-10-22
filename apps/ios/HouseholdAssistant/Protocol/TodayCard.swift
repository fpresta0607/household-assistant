// The assistant's day at a glance for the top of Chats, as its gateway keeps it: what
// `household-app.today` answers and what the plugin's `today` event carries when the
// assistant writes a new one (CFO notes section 21c). The gateway keeps only the newest,
// and the evening's carries tomorrow morning, so the phone picks what is still ahead by
// its own clock (TodayGlance).

import Foundation

struct TodayCard: Codable, Equatable, Sendable {
    /// One thing in the day: an event, a reminder or anything else the assistant knows of.
    struct Item: Codable, Equatable, Sendable {
        /// When it starts, ISO 8601 with its offset, as the assistant wrote it.
        let start: String
        let title: String
        /// A line that helps with it, such as when to leave.
        let detail: String?
        let allDay: Bool

        init(start: String, title: String, detail: String? = nil, allDay: Bool = false) {
            self.start = start
            self.title = title
            self.detail = detail
            self.allDay = allDay
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            start = try container.decode(String.self, forKey: .start)
            title = try container.decode(String.self, forKey: .title)
            detail = try container.decodeIfPresent(String.self, forKey: .detail)
            allDay = try container.decodeIfPresent(Bool.self, forKey: .allDay) ?? false
        }

        /// When it starts, or nil for a time that is not one.
        var startDate: Date? {
            ISO8601DateFormatter().date(from: start)
        }
    }

    /// The verse at the bottom: the morning devotional's, or one chosen for the day.
    struct Verse: Codable, Equatable, Sendable {
        let text: String
        let reference: String
        /// Where it opens in the Bible app. Only the scripture skill's bible.com links.
        let link: URL?

        init(text: String, reference: String, link: URL?) {
            self.text = text
            self.reference = reference
            self.link = link
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            text = try container.decode(String.self, forKey: .text)
            reference = try container.decode(String.self, forKey: .reference)
            let link = try container.decodeIfPresent(String.self, forKey: .link).flatMap(URL.init(string:))
            self.link = link?.scheme == "https" && link?.host == "www.bible.com" ? link : nil
        }
    }

    /// The gateway's own day it was written on, `YYYY-MM-DD`.
    let day: String
    /// When it was written, in milliseconds.
    let at: Int
    let items: [Item]
    let verse: Verse?

    static let eventName = "plugin.household-app.today"
}
