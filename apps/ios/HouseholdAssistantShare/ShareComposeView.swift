// The Share Extension's sheet: pick the family room or your assistant's thread by their
// faces, see what goes, add words, and send. It says before Send that Steward AI sends it
// signed by this iPhone, and after Send that it is on its way, for a moment, before the
// sheet closes.
//
// Drawn from what the app leaves in the App Group for the widgets: the faces, the
// assistant's name and whether this iPhone is paired. Compiled into the app as well, so
// the screenshot tests draw it.

import SwiftUI
import UIKit

struct ShareComposeView: View {
    let snapshot: WidgetSnapshot
    let photos: [String: UIImage]
    let previews: [ShareSheetItem]
    /// Something to say about what was shared: a thing left out, or why none of it can go.
    let notice: String?
    /// Whether what was shared cannot go as it is.
    let isRefused: Bool
    let isLoading: Bool
    let isSent: Bool
    let onCancel: () -> Void
    let onSend: (RoomConversation, String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var conversation: RoomConversation
    @State private var words: String

    private static let faceSize: CGFloat = 76
    private static let tileSide: CGFloat = 84

    /// `conversation` is the one picked in the Share Sheet's top row, when one was.
    init(
        snapshot: WidgetSnapshot,
        photos: [String: UIImage],
        previews: [ShareSheetItem],
        conversation: RoomConversation,
        words: String = "",
        notice: String? = nil,
        isRefused: Bool = false,
        isLoading: Bool = false,
        isSent: Bool = false,
        onCancel: @escaping () -> Void,
        onSend: @escaping (RoomConversation, String) -> Void
    ) {
        self.snapshot = snapshot
        self.photos = photos
        self.previews = previews
        self.notice = notice
        self.isRefused = isRefused
        self.isLoading = isLoading
        self.isSent = isSent
        self.onCancel = onCancel
        self.onSend = onSend
        _conversation = State(initialValue: conversation)
        _words = State(initialValue: words)
    }

    private var isPaired: Bool {
        snapshot.me != nil
    }

    private var canSend: Bool {
        isPaired && !isLoading && !isRefused && !isSent
            && (!previews.isEmpty || !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        ZStack {
            MeshBackground()
            VStack(spacing: 0) {
                header
                if !isPaired {
                    unpaired
                } else if isSent {
                    sent
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.92).combined(with: .opacity))
                } else {
                    compose
                        .transition(.opacity)
                }
            }
        }
        .foregroundStyle(Palette.text)
        .tint(Palette.highlight)
        .animation(Motion.arrive(reduced: reduceMotion), value: isSent)
        .animation(Motion.arrive(reduced: reduceMotion), value: previews.map(\.id))
        .animation(Motion.fade, value: notice)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            Button("Cancel", systemImage: "xmark", action: onCancel)
                .labelStyle(.iconOnly)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: Circle())
                .opacity(isSent ? 0 : 1)
                .accessibilityHidden(isSent)
            Spacer()
            Text("Steward AI")
                .font(.headline)
            Spacer()
            Button {
                onSend(conversation, words)
            } label: {
                Image(systemName: "arrow.up")
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Palette.highlight, in: Circle())
            }
            .disabled(!canSend)
            .opacity(isPaired && !isSent ? (canSend ? 1 : 0.4) : 0)
            .accessibilityLabel("Send to \(name(of: conversation))")
            .accessibilityHidden(!isPaired || isSent)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var compose: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 12) {
                    Text("Send to")
                        .font(.footnote.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(Palette.secondaryText)
                        .accessibilityAddTraits(.isHeader)
                    HStack(alignment: .top, spacing: 36) {
                        ForEach([RoomConversation.direct, .family], id: \.self) { choice in
                            choiceButton(choice)
                        }
                    }
                }
                if isLoading || !previews.isEmpty {
                    strip
                }
                TextField("Add a message", text: $words, axis: .vertical)
                    .lineLimit(1...6)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                if let notice {
                    Label(notice, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(Palette.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.errorSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .transition(.opacity)
                }
                Label("Steward AI sends it the moment the app is open, signed by this iPhone.", systemImage: "checkmark.seal")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// A conversation by its face and name, ringed in royal with a tick while it is the one.
    private func choiceButton(_ choice: RoomConversation) -> some View {
        let isChosen = choice == conversation
        return Button {
            conversation = choice
        } label: {
            VStack(spacing: 8) {
                face(of: choice, size: Self.faceSize)
                    .padding(4)
                    .overlay {
                        Circle()
                            .strokeBorder(Palette.highlight, lineWidth: 3)
                            .opacity(isChosen ? 1 : 0)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if isChosen {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title2)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Palette.highlight)
                                .transition(Motion.popTransition(reduced: reduceMotion))
                        }
                    }
                    .shadow(color: Palette.shadow, radius: 10, y: 5)
                Text(name(of: choice))
                    .font(.subheadline.weight(isChosen ? .semibold : .regular))
                    .lineLimit(1)
            }
            .opacity(isChosen ? 1 : 0.7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.press(reduced: reduceMotion), value: isChosen)
        .accessibilityLabel(name(of: choice))
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    @ViewBuilder
    private func face(of choice: RoomConversation, size: CGFloat) -> some View {
        switch choice {
        case .family:
            WidgetFamilyFace(faces: snapshot.faces, photos: photos, size: size)
        case .direct:
            let thread = WidgetConversation(conversation: .direct, snapshot: snapshot, photos: photos)
            WidgetFace(look: thread.assistantLook, photo: thread.photo(of: snapshot.assistant), size: size, ring: snapshot.face(snapshot.assistant)?.ring)
        }
    }

    private func name(of choice: RoomConversation) -> String {
        WidgetConversation(conversation: choice, snapshot: snapshot, photos: photos).title
    }

    /// What goes with the words, in the order it was shared.
    private var strip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(previews) { preview in
                    tile(preview)
                        .transition(Motion.popTransition(reduced: reduceMotion))
                }
                if isLoading {
                    ProgressView()
                        .frame(width: Self.tileSide, height: Self.tileSide)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityLabel("Getting it ready")
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    private func tile(_ preview: ShareSheetItem) -> some View {
        ZStack {
            if let thumbnail = preview.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Palette.surface
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: symbol(for: preview.kind))
                        .font(.title3)
                        .foregroundStyle(Palette.highlight)
                    Spacer(minLength: 0)
                    Text(preview.title)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(3)
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            if preview.kind == .video {
                Image(systemName: "play.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .glassEffect(.regular, in: Circle())
            }
        }
        .frame(width: preview.kind == .link || preview.kind == .text ? Self.tileSide * 1.8 : Self.tileSide, height: Self.tileSide)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Palette.shadow, radius: 6, y: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(description(of: preview))
    }

    private func symbol(for kind: ShareSheetItem.Kind) -> String {
        switch kind {
        case .photo:
            return "photo"
        case .video:
            return "video.fill"
        case .file:
            return "doc.fill"
        case .link:
            return "link"
        case .text:
            return "text.quote"
        }
    }

    private func description(of preview: ShareSheetItem) -> String {
        switch preview.kind {
        case .photo:
            return "Photo"
        case .video:
            return "Video"
        case .file, .text:
            return preview.title
        case .link:
            return "Link to \(preview.title)"
        }
    }

    /// The conversation's face with a tick, and what happens next.
    private var sent: some View {
        VStack(spacing: 16) {
            Spacer()
            face(of: conversation, size: 96)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 34))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Palette.highlight)
                        .offset(x: 6, y: 6)
                }
                .shadow(color: Palette.shadow, radius: 14, y: 6)
            Text("On its way to \(name(of: conversation))")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Steward AI sends it the moment the app is open, signed by this iPhone.")
                .font(.subheadline)
                .foregroundStyle(Palette.secondaryText)
                .multilineTextAlignment(.center)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var unpaired: some View {
        ContentUnavailableView(
            "Pair this iPhone first",
            systemImage: "link.badge.plus",
            description: Text("Open Steward AI and pair it with your assistant, then share this again.")
        )
    }
}
