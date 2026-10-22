// Something picked for the next message and waiting in the composer: what will be sent,
// and the small picture the composer shows of it until then.

import UIKit

struct StagedAttachment: Identifiable {
    let id = UUID()
    let attachment: RoomAttachment
    /// Nil for a file, which shows its kind instead.
    let preview: UIImage?
}
