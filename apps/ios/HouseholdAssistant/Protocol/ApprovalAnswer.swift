// What this phone signs to answer an approval card, exactly as
// deploy/openclaw/plugins/household-app/approvals.js builds it.
//
// The gateway gives OpenClaw a yes for its owner only when one of the owner's phones
// signed it, with the key this phone pairs with, so neither an assistant nor another
// client can approve anything for them.

import Foundation

enum ApprovalAnswer {
    static let version = "household-app/approval/v1"

    /// Nil for an approval id that would span two lines, which no card should carry.
    static func signedText(approvalId: String, decision: RoomApproval.Decision) -> String? {
        // By scalar, since "\r\n" is one Character and would hide from a Character search.
        guard !approvalId.isEmpty, !approvalId.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            return nil
        }
        return [version, approvalId, decision.rawValue].joined(separator: "\n")
    }
}
