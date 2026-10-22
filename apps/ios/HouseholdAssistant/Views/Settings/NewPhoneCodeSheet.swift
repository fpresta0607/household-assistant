// Pair a new iPhone, over Account: the setup code this phone's gateway just issued, as a
// QR code of its link for the new iPhone's camera, Share to send the link to it, and the
// code itself to copy into the app there. It works once, for ten minutes, and Account
// forgets it once this closes.

import SwiftUI

struct NewPhoneCodeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let phones = model.pairedPhones
        NavigationStack {
            ZStack {
                MeshBackground()
                ScrollView {
                    Group {
                        if let code = phones.newPhoneCode {
                            shown(code)
                        } else if let refusal = phones.codeRefusal {
                            refused(refusal)
                        } else {
                            ProgressView()
                                .controlSize(.large)
                                .frame(maxWidth: .infinity, minHeight: 320)
                                .accessibilityLabel("Asking \(model.assistantName) for a code")
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle("Pair a new iPhone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func shown(_ code: NewPhoneCode) -> some View {
        VStack(spacing: 24) {
            QRCodeImage(code.link.absoluteString)
                .frame(width: 224, height: 224)
                .padding(18)
                .background(.white, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .shadow(color: Palette.shadow, radius: 18, y: 8)
                .accessibilityLabel("QR code that pairs a new iPhone")
            Text("Install Steward AI on the new iPhone, then point its camera at this or share the link to it. It joins as you.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.text)
            ShareLink(item: code.link) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(minWidth: 140, minHeight: 30)
            }
            .buttonStyle(.glass)
            .tint(Palette.highlight)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Or paste this code there")
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryText)
                    Text(code.setupCode)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(Palette.text)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                CopyButton(text: code.setupCode, title: "Copy code")
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .tint(Palette.highlight)
                    .accessibilityLabel("Copy the code")
            }
            .padding(16)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Label("It works once, for 10 minutes.", systemImage: "clock")
                .font(.footnote)
                .foregroundStyle(Palette.secondaryText)
        }
    }

    private func refused(_ refusal: String) -> some View {
        VStack(spacing: 16) {
            Label(refusal, systemImage: "exclamationmark.triangle.fill")
                .font(.body)
                .foregroundStyle(Palette.text)
            Button("Try again") {
                Task {
                    await model.pairedPhones.askForCode()
                }
            }
            .buttonStyle(.glass)
            .tint(Palette.highlight)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}
