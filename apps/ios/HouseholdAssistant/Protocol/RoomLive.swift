// A live map's newest move, as the gateway keeps it: when its phone signed it, and where.
// A move with no position stopped the share.

import Foundation

struct RoomLive: Decodable, Equatable, Sendable {
    let at: Int
    let position: LocationReport.Position?
}
