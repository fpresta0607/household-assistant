// An answer read twice from the same payload: as the model its request wanted, and as the
// JSON the gateway sent, for a phone that keeps it (RoomArchive) and reads it back later
// through the same model. Both readings happen where the frame is decoded, away from the
// main actor.

import Foundation

struct KeptAnswer<Model: Decodable & Sendable>: Decodable, Sendable {
    let model: Model
    let json: JSONValue

    init(from decoder: Decoder) throws {
        model = try Model(from: decoder)
        json = try JSONValue(from: decoder)
    }
}
