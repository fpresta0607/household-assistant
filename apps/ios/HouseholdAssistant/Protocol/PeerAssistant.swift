// The other household's assistant, as `household-app.sync` carries it across the relay
// the way the room carries faces: who she is, her voice and her model, for her page in
// the family room. Only her own person changes any of it, so this phone only shows it.

import Foundation

struct PeerAssistant: Decodable, Equatable, Sendable {
    let name: String
    let voiceName: String
    /// Her voice's id, which this phone's own gateway speaks her sample in.
    let voice: String
    let modelName: String
    /// How she takes part in the family room, in the gateway's words.
    let familyRoom: String
}
