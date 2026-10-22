// A compact table of contents anchored above the composer. Only this glass card covers
// the conversation; the list scrolls within the space RoomView gives it.

import SwiftUI

struct ThreadSearchResults: View {
    @Bindable var search: ThreadSearchModel
    var maximumHeight: CGFloat = 280
    let onPick: (Int) -> Void

    @Environment(AppModel.self) private var model
    @State private var contentHeight: CGFloat = 280

    var body: some View {
        // The header scrolls with the rows at large text sizes and in a short landscape
        // viewport, so every control remains reachable without covering the whole chat.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(search.position)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.text)
                        .accessibilityIdentifier("search.count")
                    Spacer(minLength: 0)
                    Button {
                        search.isListShown = false
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Palette.highlight)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hide search results")
                    .accessibilityIdentifier("search.collapse")
                }
                .padding(.leading, 16)
                .padding(.trailing, 4)
                filters
                if search.isReady {
                    ForEach(Array(search.matches.enumerated()), id: \.element.id) { index, match in
                        Button {
                            onPick(index)
                        } label: {
                            row(match)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("search.result")
                        Divider()
                            .padding(.leading, 16)
                    }
                }
                if let status {
                    HStack(spacing: 8) {
                        if !search.isReady || search.isReadingOlder {
                            ProgressView()
                        }
                        Text(status)
                    }
                    .font(.subheadline)
                    .foregroundStyle(Palette.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .accessibilityIdentifier("search.status")
                }
                if search.canSearchOlder, !search.isReadingOlder {
                    Button(search.historyError ? "Retry older messages" : "Search older messages") {
                        search.searchOlder()
                    }
                    .font(.subheadline)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("search.older")
                }
            }
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                contentHeight = height
            }
        }
        .frame(height: min(maximumHeight, contentHeight))
        .scrollDismissesKeyboard(.never)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .rainbowGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityIdentifier("search.results")
    }

    private var filters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(ThreadSearch.Filter.allCases) { filter in
                    Button {
                        search.filter = filter
                    } label: {
                        Text(filter.label)
                            .font(.subheadline.weight(search.filter == filter ? .semibold : .regular))
                            .foregroundStyle(search.filter == filter ? Palette.highlight : Palette.secondaryText)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background {
                                Capsule()
                                    .fill(Palette.highlight.opacity(search.filter == filter ? 0.06 : 0))
                            }
                            .overlay {
                                Capsule()
                                    .strokeBorder(
                                        search.filter == filter ? Palette.highlight.opacity(0.6) : Palette.secondaryText.opacity(0.18),
                                        lineWidth: 1
                                    )
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(search.filter == filter ? .isSelected : [])
                    .accessibilityIdentifier("search.filter.\(filter.rawValue)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        .scrollIndicators(.hidden)
    }

    private var status: String? {
        if !search.isReady { return "Searching" }
        if search.isReadingOlder { return "Looking through older messages" }
        if search.matches.count == ThreadSearch.mostMatches { return "Showing the newest 500 matches. Refine your search for more." }
        if search.historyError { return "Older messages could not be loaded" }
        return search.matches.isEmpty ? "No results" : nil
    }

    private func row(_ match: ThreadSearch.Match) -> some View {
        let divider = MessageTime.divider(for: match.sentAt)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let symbol = Self.symbol(for: match.source) {
                    Image(systemName: symbol)
                        .foregroundStyle(Palette.highlight)
                }
                Text(model.room.participant(match.author)?.name ?? "")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.text)
                Spacer(minLength: 8)
                Text("\(divider.day) \(divider.time)")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryText)
            }
            Text("\(Text(match.snippet[..<match.found.lowerBound]))\(Text(match.snippet[match.found]).fontWeight(.bold))\(Text(match.snippet[match.found.upperBound...]))")
                .font(.subheadline)
                .foregroundStyle(Palette.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// What a match found somewhere other than a message's words is marked with.
    private static func symbol(for source: ThreadSearch.Source) -> String? {
        switch source {
        case .words:
            return nil
        case .voiceNote:
            return RoomMediaSymbol.name(for: .voice)
        case .photo:
            return RoomMediaSymbol.name(for: .photo)
        case .video:
            return RoomMediaSymbol.name(for: .video)
        case .file:
            return RoomMediaSymbol.name(for: .file)
        case .call:
            return "phone.fill"
        }
    }
}

