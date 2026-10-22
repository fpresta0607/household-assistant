// The household's shared cart, in the lists' mint: a row for each item with its picture,
// how many, who it is for and who added it, then Check out and Ordered.
//
// Check out opens the Amazon link: the Amazon app takes it when it is on the phone, else
// Safari, and the phone itself never talks to Amazon. Ordered, tapped once he has paid
// there, tells the gateway, which posts the cart as it now stands and his order as new
// messages. A newer cart with the same id takes this one's place, which then shrinks to a
// line saying so: the thread works out which carts have been replaced once each time it
// changes (CartReplacements), so no cart reads the messages after its own.

import SwiftUI

struct CartCardView: View {
    let cart: CartCard
    /// Nil until the gateway has kept the message.
    let messageId: String?
    let conversation: RoomConversation
    /// Whether a later message carries this cart as it is now.
    let isReplaced: Bool

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.reducesMotion) private var reduceMotion
    @State private var isMarking = false
    @State private var refusal: String?
    /// Counts the times the gateway took Ordered, for the tap back.
    @State private var timesOrdered = 0

    var body: some View {
        // The line takes the card's place at once, with no spring on the row's height.
        if isReplaced {
            Label("The cart has changed. It is below as it is now.", systemImage: "cart")
                .font(.footnote)
                .foregroundStyle(CardStyle.secondaryInk)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardPanel(tint: CardStyle.listsGreen)
                .transition(Motion.rowTransition)
        } else {
            card
                .transition(Motion.rowTransition)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 4) {
            CardHeader(symbol: "cart.fill", tint: CardStyle.listsGreen, kind: "Cart", title: cart.title, note: count)
                .padding(.bottom, 4)
            if cart.items.isEmpty {
                Text("Nothing in the cart.")
                    .font(.subheadline)
                    .foregroundStyle(CardStyle.secondaryInk)
                    .padding(.vertical, 4)
            }
            ForEach(Array(cart.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Divider()
                        .overlay(CardStyle.hairline)
                }
                row(item)
            }
            if !cart.items.isEmpty {
                buttons
                    .padding(.top, 8)
            }
            if let refusal {
                Text(refusal)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 2)
                    .transition(.opacity)
            }
        }
        .padding(12)
        .cardPanel(tint: CardStyle.listsGreen)
        .animation(Motion.press(reduced: reduceMotion), value: isMarking)
        .animation(Motion.press(reduced: reduceMotion), value: refusal)
        .haptic(.success, trigger: timesOrdered)
    }

    /// "4 items", each counted as many times as it is wanted.
    private var count: String? {
        let total = cart.items.map(\.quantity).reduce(0, +)
        guard total > 0 else {
            return nil
        }
        return total == 1 ? "1 item" : "\(total) items"
    }

    private func row(_ item: CartCard.Item) -> some View {
        Button {
            if let url = item.url {
                openURL(url)
            }
        } label: {
            HStack(spacing: 12) {
                picture(item)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CardStyle.ink)
                        .multilineTextAlignment(.leading)
                    Text("For \(item.forPerson) \u{00B7} added by \(item.by)")
                        .font(.caption)
                        .foregroundStyle(CardStyle.secondaryInk)
                }
                Spacer(minLength: 4)
                Text("\(item.quantity)\u{00D7}")
                    .font(.footnote.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(CardStyle.listsInk)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(CardStyle.listsGreen.opacity(0.14), in: Capsule())
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.url == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.quantity) \(item.name), for \(item.forPerson), added by \(item.by)")
        .accessibilityHint(item.url == nil ? "" : "Opens it on Amazon")
    }

    /// The item's picture, or a bag in mint until it loads or when it has none.
    private func picture(_ item: CartCard.Item) -> some View {
        CardPicture(url: item.image, size: CGSize(width: 44, height: 44)) {
            Image(systemName: "bag")
                .font(.subheadline)
                .foregroundStyle(CardStyle.listsInk.opacity(0.7))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CardStyle.listsGreen.opacity(0.12))
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if let checkout = cart.checkout {
                Button {
                    openURL(checkout)
                } label: {
                    Label("Check out", systemImage: "arrow.up.forward.app")
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                }
                .accentGlass(CardStyle.accent)
            }
            Button {
                Task {
                    await markOrdered()
                }
            } label: {
                HStack(spacing: 8) {
                    if isMarking {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "shippingbox")
                    }
                    Text("Ordered")
                }
                .frame(maxWidth: cart.checkout == nil ? .infinity : nil)
            }
            .buttonStyle(.glass)
            .tint(CardStyle.listsInk)
            .disabled(isMarking || messageId == nil)
            .accessibilityHint("Says you checked these out on Amazon")
        }
        .font(.subheadline.weight(.semibold))
    }

    private func markOrdered() async {
        guard let messageId else {
            return
        }
        refusal = nil
        isMarking = true
        do {
            _ = try await model.room.markOrdered(cartIn: messageId, in: conversation)
            timesOrdered += 1
        } catch {
            refusal = ErrorText.describe(error)
        }
        isMarking = false
    }
}
