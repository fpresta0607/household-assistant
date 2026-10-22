// Where everyone sits in the family room's one circle of faces, the way a group shows in
// Messages: this phone's person top left with the other person across from them, and the
// two assistants on the other diagonal. The room's face in the app (FamilyAvatar) and in
// the widgets both seat them this way.

import Foundation

enum FamilyFaces {
    /// Everyone in the room in seat order, across and then down. The circle shows the
    /// first four.
    static func arranged(_ participants: [RoomParticipant]) -> [RoomParticipant] {
        let people = participants.filter { $0.kind == .person }.sorted { $0.isOwner && !$1.isOwner }
        let assistants = participants.filter { $0.kind == .assistant }
        return Array(people.prefix(1)) + assistants + Array(people.dropFirst())
    }
}
