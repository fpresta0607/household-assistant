// Something about to be sent with a message: a voice note just recorded, a photo or a
// video picked, a file. Its bytes go up in chunks before the message itself is sent.

import Foundation

struct RoomAttachment: Codable, Equatable, Sendable {
    let data: Data
    let kind: RoomMedia.Kind
    let mime: String
    var durationMs: Int?
    var width: Int?
    var height: Int?
    var waveform: [Double]?
    var name: String?

    /// The plugin's limits: ten attachments in one message, 50 MB each, and 120 MB
    /// together, which is as much as the family room's relay carries to the other
    /// gateway in one delivery.
    static let mostPerMessage = 10
    static let largestBytes = 50 * 1024 * 1024
    static let largestMessageBytes = 120 * 1024 * 1024

    /// Why attachments of these sizes cannot go in one message, in words for the
    /// person, or nil when they can.
    static func refusal(sizes: [Int]) -> String? {
        if sizes.count > mostPerMessage {
            return "Up to ten things go in one message"
        }
        if sizes.contains(where: { $0 > largestBytes }) {
            return "That is too large to send"
        }
        if sizes.reduce(0, +) > largestMessageBytes {
            return "Those are too large to send together"
        }
        return nil
    }

    /// What the message carries once the gateway has the bytes and named them.
    func media(id: String) -> RoomMedia {
        RoomMedia(
            id: id,
            kind: kind,
            mime: mime,
            bytes: data.count,
            durationMs: durationMs,
            width: width,
            height: height,
            waveform: waveform,
            name: name
        )
    }
}
