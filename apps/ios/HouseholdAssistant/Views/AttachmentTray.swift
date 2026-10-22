// What waits to go with the next message, in a row at the top of the composer's field:
// a small picture of each photo and video, the kind of each file, and a cross to take
// any of them out again. All of them go in one message with the words.

import SwiftUI

struct AttachmentTray: View {
    let staged: [StagedAttachment]
    let onRemove: (StagedAttachment) -> Void

    private static let side: CGFloat = 64

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(staged) { item in
                    tile(item)
                        .overlay(alignment: .topTrailing) {
                            Button {
                                onRemove(item)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title3)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Palette.navyDeep.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .padding(2)
                            .accessibilityLabel("Take out \(description(of: item))")
                        }
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private func tile(_ item: StagedAttachment) -> some View {
        ZStack {
            if let preview = item.preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFill()
            } else {
                Palette.surface
                VStack(spacing: 3) {
                    Image(systemName: "doc.fill")
                        .font(.title3)
                    Text(FileTypeLabel.label(name: item.attachment.name, mime: item.attachment.mime))
                        .font(.caption2.weight(.heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .foregroundStyle(Palette.highlight)
                .padding(4)
            }
            if item.attachment.kind == .video {
                Image(systemName: "play.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.mediaGlassText)
                    .frame(width: 24, height: 24)
                    .liquidGlass(.regular, in: Circle())
            }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(description(of: item))
    }

    private func description(of item: StagedAttachment) -> String {
        switch item.attachment.kind {
        case .photo:
            return "Photo"
        case .video:
            return "Video"
        case .voice:
            return "Voice note"
        case .file:
            return item.attachment.name ?? "File"
        }
    }
}
