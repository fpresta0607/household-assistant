// What was said on a call, opened from its row: each line under who said it, in order.
// Only the words were kept, never the sound; a long call keeps only its start, and says so.

import SwiftUI
import UIKit

struct CallTranscriptSheet: View {
    let call: RoomCall
    let sentAt: Date

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("\(sentAt.formatted(date: .abbreviated, time: .shortened)), \(call.length)")
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondaryText)
                    if call.transcript.isEmpty {
                        Text("Nothing was said on this call.")
                            .foregroundStyle(Palette.secondaryText)
                    }
                    ForEach(Array(call.transcript.enumerated()), id: \.offset) { _, line in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(name(of: line.author))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Palette.secondaryText)
                            Text(line.text)
                                .foregroundStyle(Palette.text)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if call.isCut {
                        Text("Only the start of this call was kept.")
                            .font(.footnote)
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Call with \(name(of: call.assistant))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !call.transcript.isEmpty {
                        Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                            UIPasteboard.general.string = call.transcript.map { "\(name(of: $0.author)): \($0.text)" }.joined(separator: "\n\n")
                            copied = true
                        }
                        .accessibilityLabel("Copy call transcript")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private func name(of author: String) -> String {
        model.room.participant(author)?.name ?? (author == call.assistant ? model.assistantName : "You")
    }
}
