// Says, in one line, what a person has to do before the assistant can be reached: wait for
// an approval, pair again, or read why it cannot connect. A link that is only coming back
// shows nothing here: the title says "Connecting" quietly in place of its own
// (comingBackTitle), so a spotty network never flashes a banner over the chat, and
// everything already here stays readable.

import SwiftUI

struct ConnectionBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let content {
            HStack(spacing: 12) {
                Image(systemName: content.symbol)
                    .symbolEffect(.variableColor.iterative, isActive: content.isWorking)
                VStack(alignment: .leading, spacing: 2) {
                    Text(content.title)
                        .font(.subheadline.weight(.semibold))
                    if let detail = content.detail {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
                Spacer(minLength: 0)
                if content.offersPairing {
                    Button("Pair again") {
                        model.forgetPairing()
                    }
                    .buttonStyle(.glass)
                }
            }
            .foregroundStyle(Palette.text)
            .padding(12)
            .background(
                content.isProblem ? Palette.errorSurface : Palette.surface,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .padding(.horizontal, 16)
            .accessibilityElement(children: .combine)
        }
    }

    private struct Content {
        let symbol: String
        let title: String
        var detail: String?
        var isWorking = false
        var isProblem = false
        var offersPairing = false
    }

    private var content: Content? {
        guard model.connectionNotice.isShown else {
            return nil
        }
        switch model.connection.state {
        case .connected, .disconnected, .connecting, .reconnecting:
            return nil
        case .pairingPending(let requestId):
            return Content(
                symbol: "hourglass",
                title: "Waiting for approval",
                detail: requestId.map { "Request \($0) is waiting on the server." },
                isWorking: true
            )
        case .needsPairing(let message):
            return Content(symbol: "link.badge.plus", title: "Pairing needed", detail: message, offersPairing: true)
        case .failed(let message):
            return Content(symbol: "exclamationmark.triangle", title: "Cannot connect", detail: message, isProblem: true)
        }
    }
}
