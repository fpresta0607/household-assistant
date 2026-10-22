// Search from what was shared, on Chats (CFO notes section 5): the photos, videos and
// files of both conversations, found by their message's words or a file's name, with
// every older page of each conversation read first so all of it is searched. A tap picks
// one, which Chats opens once this sheet has gone, as a tap on its tile does.

import SwiftUI

struct SharedSearchView: View {
    /// The thing picked, which Chats opens as the sheet closes.
    @Binding var picked: SharedMedia?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var found: [SharedMedia] = []
    @State private var isReadingOlder = true

    var body: some View {
        NavigationStack {
            List(found) { item in
                Button {
                    picked = item
                    dismiss()
                } label: {
                    row(item)
                }
                .accessibilityIdentifier("shared.result")
            }
            .listStyle(.plain)
            .overlay {
                if found.isEmpty {
                    Text(status)
                        .font(.subheadline)
                        .foregroundStyle(Palette.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(24)
                        .accessibilityIdentifier("shared.status")
                }
            }
            .navigationTitle("Search what was shared")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Photos, videos and files")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            for conversation in RoomConversation.allCases {
                await model.room.loadAll(conversation)
            }
            isReadingOlder = false
        }
        .task(id: "\(query) \(RoomConversation.allCases.map { model.room.thread($0).messages.count })") {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else {
                return
            }
            let query = self.query
            let conversations = RoomConversation.allCases.map { ($0, model.room.thread($0).messages) }
            let matching = await Task.detached(priority: .userInitiated) {
                SharedMedia.matching(query, in: conversations)
            }.value
            if !Task.isCancelled {
                found = matching
            }
        }
    }

    private var status: String {
        if query.isEmpty {
            return "Search the photos, videos and files shared in both chats."
        }
        return isReadingOlder ? "Looking through older messages" : "No results"
    }

    private func row(_ item: SharedMedia) -> some View {
        let message = model.room.thread(item.conversation).messages.first { $0.media.contains(item.media) }
        let words = message?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let divider = MessageTime.divider(for: item.sentAt)
        let sender = model.room.participant(item.author)?.name ?? ""
        let place = item.conversation == .family ? "in The Fam" : "in your chat with \(model.assistantName)"
        return HStack(spacing: 12) {
            Image(systemName: RoomMediaSymbol.name(for: item.media.kind))
                .font(.title3)
                .foregroundStyle(Palette.highlight)
                .frame(width: 40, height: 40)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.media.name ?? (words.isEmpty ? Self.kindName(item.media.kind) : words))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.text)
                    .lineLimit(2)
                Text("\(sender), \(place), \(divider.day) \(divider.time)")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
            }
        }
        .contentShape(Rectangle())
    }

    private static func kindName(_ kind: RoomMedia.Kind) -> String {
        switch kind {
        case .photo:
            return "Photo"
        case .video:
            return "Video"
        case .voice:
            return "Voice note"
        case .file:
            return "File"
        }
    }
}
