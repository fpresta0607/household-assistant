// Franco's list of iPhones that signed in with Apple and wait to join, on his gateway
// or Gia's, each with a button that lets it in. A group on Account, shown only while
// somebody waits, and only his gateway ever lists anyone.

import SwiftUI

struct SignInApprovalsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let approvals = model.signInApprovals
        if !approvals.waiting.isEmpty {
            SettingsGroup(
                "Waiting to join",
                note: "Let an iPhone in only when you know who just signed in on it.",
                refusal: approvals.refusal
            ) {
                ForEach(approvals.waiting) { request in
                    row(request)
                }
            }
        }
    }

    private func row(_ request: AppleSignInRequest) -> some View {
        let person = HouseholdMember(rawValue: request.person)?.name ?? request.person
        let asked = Date(timeIntervalSince1970: Double(request.at) / 1000)
        return SettingsRow(request.name, subtitle: "Joins as \(person), asked \(asked.formatted(.relative(presentation: .named)))") {
            SymbolTile("iphone", color: Palette.gold)
        } trailing: {
            Button("Let in") {
                Task {
                    await model.signInApprovals.approve(request)
                }
            }
            .buttonStyle(.glass)
            .tint(Palette.highlight)
        }
        .accessibilityElement(children: .combine)
    }
}
