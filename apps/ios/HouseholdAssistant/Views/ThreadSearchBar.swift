// Search uses the normal composer's place, spacing, glass and send arrow. The message
// draft stays in RoomComposer. Picking a match dismisses the keyboard and results list.

import SwiftUI

struct ThreadSearchBar: View {
    @Bindable var search: ThreadSearchModel
    let onDone: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            GlassEffectContainer(spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    Button {
                        isFocused = false
                        onDone()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(Palette.text)
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                            .liquidGlass(.regular.interactive(), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close search")
                    .accessibilityIdentifier("search.done")
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Palette.secondaryText)
                            .accessibilityHidden(true)
                        TextField("Search this chat", text: $search.query)
                            .focused($isFocused)
                            .submitLabel(.search)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .foregroundStyle(Palette.text)
                            .padding(.vertical, 11)
                            .onSubmit { search.submit() }
                            .accessibilityIdentifier("search.field")
                        if !search.query.isEmpty {
                            Button {
                                search.query = ""
                                isFocused = true
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Palette.secondaryText)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear the search")
                            .accessibilityIdentifier("search.clear")
                        }
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 8)
                    .frame(minHeight: 44)
                    .liquidGlass(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    Button {
                        search.submit()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(Palette.highlight)
                            .frame(width: MicrophoneOrb.size, height: MicrophoneOrb.size)
                            .liquidGlass(.regular.interactive(), in: Circle())
                            .overlay {
                                Circle()
                                    .strokeBorder(Palette.highlight.opacity(0.55), lineWidth: 1.5)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(!search.hasQuery)
                    .opacity(search.hasQuery ? 1 : 0.4)
                    .accessibilityLabel("Go to first result")
                    .accessibilityIdentifier("search.submit")
                }
            }
            if search.hasQuery, !search.isListShown, !isFocused {
                ThreadSearchSteps(search: search) { isOlder in
                    search.step(isOlder: isOlder)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear { isFocused = true }
        .onChange(of: isFocused) { _, focused in
            if focused { search.isListShown = true }
        }
        .onChange(of: search.isListShown) { _, shown in
            if !shown { isFocused = false }
        }
    }
}

