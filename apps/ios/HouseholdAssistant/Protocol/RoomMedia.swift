// One attachment, as the household-app plugin keeps it: named by the SHA-256 of its
// bytes, which the gateway hands back when an upload completes.

import Foundation

struct RoomMedia: Codable, Equatable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case voice, photo, video, file

        /// A photo or a video: what shows as a picture and opens full screen.
        var isVisual: Bool {
            self == .photo || self == .video
        }
    }

    /// The id a message's attachment has on this phone until the gateway names it.
    static let pendingPrefix = "pending:"

    /// Still on its way up, so there is nothing to read back yet.
    var isPending: Bool {
        id.hasPrefix(Self.pendingPrefix)
    }

    let id: String
    let kind: Kind
    let mime: String
    let bytes: Int
    var durationMs: Int?
    var width: Int?
    var height: Int?
    /// 0...1, one value per bar the bubble draws.
    var waveform: [Double]?
    var name: String?

    init(
        id: String,
        kind: Kind,
        mime: String,
        bytes: Int,
        durationMs: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        waveform: [Double]? = nil,
        name: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.mime = mime
        self.bytes = bytes
        self.durationMs = durationMs
        self.width = width
        self.height = height
        self.waveform = waveform
        self.name = name
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, mime, bytes, durationMs, width, height, waveform, name
    }

    /// A kind a later gateway adds is shown as a file rather than failing the page.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = Kind(rawValue: try container.decode(String.self, forKey: .kind)) ?? .file
        mime = try container.decode(String.self, forKey: .mime)
        bytes = try container.decode(Int.self, forKey: .bytes)
        durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
        width = try container.decodeIfPresent(Int.self, forKey: .width)
        height = try container.decodeIfPresent(Int.self, forKey: .height)
        waveform = try container.decodeIfPresent([Double].self, forKey: .waveform)
        name = try container.decodeIfPresent(String.self, forKey: .name)
    }

    var json: JSONValue {
        var members: [String: JSONValue] = [
            "id": .string(id),
            "kind": .string(kind.rawValue),
            "mime": .string(mime),
            "bytes": .number(Double(bytes)),
        ]
        if let durationMs {
            members["durationMs"] = .number(Double(durationMs))
        }
        if let width {
            members["width"] = .number(Double(width))
        }
        if let height {
            members["height"] = .number(Double(height))
        }
        if let waveform {
            members["waveform"] = .array(waveform.map { .number($0) })
        }
        if let name {
            members["name"] = .string(name)
        }
        return .object(members)
    }
}
