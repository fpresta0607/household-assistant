// An email laid out like one: who it is from and to, the subject, the body, and Copy and
// Reply. Reply opens Mail with the subject, and the sender when the card has an address.

import SwiftUI

struct EmailCardView: View {
    let email: EmailCard

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                header
                Text(email.subject)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(CardStyle.ink)
            }
            .padding(12)
            Divider()
                .overlay(CardStyle.hairline)
            Text(email.body)
                .font(.subheadline)
                .foregroundStyle(CardStyle.ink)
                .padding(12)
            HStack(spacing: 8) {
                CopyButton(text: email.plainText)
                    .labelStyle(.titleOnly)
                    .buttonStyle(.glass)
                if let reply = email.replyURL {
                    Button {
                        openURL(reply)
                    } label: {
                        Text("Reply")
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity)
                    }
                    .accentGlass(CardStyle.accent)
                }
            }
            .font(.subheadline.weight(.semibold))
            .padding([.horizontal, .bottom], 12)
        }
        .cardPanel()
    }

    /// "From Maple Elementary · To Gia, Franco", with the two labels in bold.
    private var header: some View {
        var line = Self.bold("From ") + AttributedString(email.senderName)
        if !email.to.isEmpty {
            line += AttributedString(" \u{00B7} ") + Self.bold("To ") + AttributedString(email.to.joined(separator: ", "))
        }
        return Text(line)
            .font(.caption)
            .foregroundStyle(CardStyle.secondaryInk)
    }

    private static func bold(_ text: String) -> AttributedString {
        var label = AttributedString(text)
        label.inlinePresentationIntent = .stronglyEmphasized
        return label
    }
}
