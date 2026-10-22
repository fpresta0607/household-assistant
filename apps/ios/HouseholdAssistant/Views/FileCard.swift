// A file in a bubble: a tag for its kind, its name and its size. A tap opens it in Quick
// Look, under its own name rather than the hash the phone keeps it by, so the title
// reads right and Quick Look knows what kind of file it is.

import QuickLook
import SwiftUI

struct FileCard: View {
    let media: RoomMedia
    let isOwn: Bool
    /// The bubble's own text colour.
    let foreground: Color

    @Environment(AppModel.self) private var model
    @State private var file: URL?
    @State private var hasFailed = false
    @State private var preview: URL?

    static let width: CGFloat = 252

    private var label: String {
        FileTypeLabel.label(name: media.name, mime: media.mime)
    }

    private var size: String {
        ByteCountFormatter.string(fromByteCount: Int64(media.bytes), countStyle: .file)
    }

    var body: some View {
        Button {
            preview = file
        } label: {
            HStack(spacing: 11) {
                tag
                VStack(alignment: .leading, spacing: 2) {
                    Text(media.name ?? "File")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("\(size) \u{00B7} \(label)")
                        .font(.caption)
                        .opacity(0.7)
                }
                .foregroundStyle(foreground)
                Spacer(minLength: 0)
                if hasFailed {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(foreground.opacity(0.7))
                } else if file == nil, !media.isPending {
                    ProgressView()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: Self.width - 8, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(file == nil)
        .quickLookPreview($preview)
        .task(id: media.id) {
            await load()
        }
        .accessibilityLabel("File, \(media.name ?? label), \(size)")
        .accessibilityHint("Opens it")
    }

    /// The kind of file on a small page: in the bubble's own text colour on this phone's
    /// blue bubble, blue elsewhere.
    private var tag: some View {
        let ink = isOwn ? Palette.playOnWhite : Palette.userBubbleText
        return Text(label)
            .font(.system(size: 9.5, weight: .heavy))
            .foregroundStyle(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.bottom, 6)
            .frame(width: 36, height: 44, alignment: .bottom)
            .background(
                isOwn
                    ? AnyShapeStyle(foreground)
                    : AnyShapeStyle(Palette.userBubbleFill),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(alignment: .top) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(ink)
                    .padding(.top, 6)
            }
            .accessibilityHidden(true)
    }

    private func load() async {
        guard !media.isPending, file == nil else {
            return
        }
        guard let kept = try? await model.media.url(for: media) else {
            hasFailed = true
            return
        }
        file = Self.named(kept, as: media.name, id: media.id)
    }

    /// The kept file under its own name, linked rather than copied where it can be. A
    /// name that is not one plain file name keeps the kept file as it is.
    private static func named(_ kept: URL, as name: String?, id: String) -> URL {
        guard let name, !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            return kept
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("quick-look/\(id)", isDirectory: true)
        let named = folder.appendingPathComponent(name, isDirectory: false)
        if FileManager.default.fileExists(atPath: named.path) {
            return named
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                try FileManager.default.linkItem(at: kept, to: named)
            } catch {
                try FileManager.default.copyItem(at: kept, to: named)
            }
            return named
        } catch {
            return kept
        }
    }
}
